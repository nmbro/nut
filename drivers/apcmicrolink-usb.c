/* apcmicrolink-usb.c - USB HID tunnel transport for the APC Microlink protocol driver
 *
 * The SCL500RMI1UC (and presumably other USB-only Microlink devices) has no
 * serial port; it exposes the same Microlink byte protocol that
 * apcmicrolink.c already speaks over RS232, tunneled instead through two
 * HID vendor-page reports on the generic APC HID vendor tunnel (the same
 * one apc_modbus.c uses for Modbus-RTU-over-USB):
 *
 *   - Output Report (host->device writes), HID vendor page 0xFF86 usage
 *     0xFC. Confirmed live as Report ID 0x90 on the SCL500RMI1UC.
 *   - Input Report (device->host reads), HID vendor page 0xFF86 usage
 *     0xFD. Confirmed live as Report ID 0x89 on the SCL500RMI1UC.
 *
 * Report IDs are discovered dynamically from the device's HID report
 * descriptor (they could differ on other devices/firmware revisions),
 * mirroring apc_modbus.c's _apc_modbus_usb_callback().
 *
 * This file only replaces the "send N bytes" / "read next available byte"
 * primitives that apcmicrolink.c's microlink_send_simple()/
 * microlink_send_write()/microlink_receive_once() sit on top of; the frame
 * construction, checksum, object cache, descriptor parser, auth and
 * outlet-group logic in apcmicrolink.c are untouched and unaware of which
 * transport is underneath.
 *
 * A background-thread reader (keeping a read continuously pending on the
 * interrupt IN endpoint, decoupled from write timing, mirroring the real
 * Windows driver's design) was tried here to see if it would improve this
 * device's occasionally-slow-to-respond behavior. A controlled A/B test
 * (two minimal standalone libusb programs, byte-identical 0xFD/0xFE
 * sequence, one threaded one not) showed the threaded version getting
 * *zero* successful replies over 10s while the sequential version got
 * several - a clear regression, not an improvement, likely from libusb's
 * synchronous API serializing event-handling between the two threads and
 * delaying the write. Reverted; this file is back to the simple
 * synchronous write-then-read design that is confirmed working.
 *
 * PROTOTYPE (2026-08-23): a *single-threaded* async listener, not the
 * two-thread design above. A wire capture during a real unresponsive
 * stretch showed the device genuinely emitting valid, correctly-checksummed
 * 0x89 tunnel replies roughly every ~10s - but the driver's own read window
 * (~1s open out of every ~5-6s retry cycle, an ~17-20% duty cycle, and
 * *zero* coverage during the multi-second sleep between retries) has real
 * odds of missing every single one. This keeps exactly one
 * libusb_interrupt_transfer() permanently outstanding via
 * libusb_submit_transfer()/a self-resubmitting callback, serviced by
 * libusb_handle_events_timeout_completed() calls made from the same thread
 * that also does the writes - no second thread, so none of the event-loop
 * contention that sank the earlier attempt applies. microlink_usb_get_char()
 * now just drains a small completed-report queue the callback fills,
 * falling back to the original synchronous get_interrupt() path if the
 * async transfer couldn't be started (non-libusb-1.0 builds, or
 * libusb_submit_transfer() failure).
 *
 * REVISION (2026-08-24): the single-threaded version above turned out not
 * to actually give continuous coverage. A libusb async transfer only gets
 * reaped/resubmitted when *something* calls libusb_handle_events*() - and
 * that only ever happened inside microlink_usb_get_char(), which the outer
 * driver loop only calls for ~1s once every ~5-6s retry cycle. Interrupt
 * endpoints are host-polled, not device-initiated: once the one outstanding
 * transfer completes, the host controller stops polling that endpoint
 * entirely until a new request is submitted - so between get_char() calls,
 * "always outstanding" silently stopped being outstanding, and a live
 * capture showed the same stale 0x89 replies still slipping through
 * unclaimed, on the same ~112s reset cadence as before this file existed.
 *
 * Fixed with a *dedicated* pump thread whose only job is calling
 * libusb_handle_events_timeout_completed() in a tight short-timeout loop -
 * nothing else. This is a different shape from the reverted two-thread
 * design above: that one had *both* threads independently doing
 * synchronous reads (each internally wanting to become "the event
 * handler"), which is what caused the regression. Here only one thread
 * ever touches the event loop; the main thread only takes a mutex to
 * drain/inspect the completed-report queue and never calls
 * libusb_handle_events*() itself (microlink_usb_flush_io() included - it
 * used to pump events directly too, which would have reintroduced a second
 * caller). Guarded by HAVE_PTHREAD in addition to WITH_LIBUSB_1_0; falls
 * back to the synchronous path if pthread support isn't available or
 * pthread_create() fails.
 *
 * Copyright (C)
 *   2026 Lukas Schmid <lukas.schmid@netcube.li>
 *   2026 Nicolai 'nmbro' Brogaard <nicolai.brogaard+nut@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "config.h"
#include "main.h"

#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
#ifdef HAVE_PTHREAD
#include <pthread.h>
#endif /* HAVE_PTHREAD */

#include "nut_stdint.h"
#include "nut_libusb.h"
#include "usb-common.h"
#include "hidparser.h"

#include "apcmicrolink-usb.h"

/* American Power Conversion */
#define APC_VENDORID	0x051d

/* HID vendor page 0xFF86, usages 0xFC (host->device) / 0xFD (device->host) -
 * the same generic raw-byte HID tunnel apc_modbus.c's
 * modbus_rtu_usb_usage_rx/tx use for Modbus-RTU-over-USB. Numerically
 * identical usages, different upper protocol riding over them. */
static const HIDNode_t mlink_usb_usage_out = 0xff8600fcUL;
static const HIDNode_t mlink_usb_usage_in  = 0xff8600fdUL;

/* Report IDs behind those usages, discovered per-device at open time.
 * Expected to be 0x90 (out) / 0x89 (in) on the SCL500RMI1UC, but never
 * hardcoded - other devices/firmware could number them differently. */
static int mlink_report_out = 0;
static int mlink_report_in = 0;

/* Standard HID Power/Battery System Page usages behind the "foreign"
 * background reports this device also pushes on the same interrupt pipe,
 * independent of the Microlink tunnel's health - confirmed live against
 * this exact device (report descriptor walk + a real usbhid-ups side by
 * side run). Looked up by usage rather than assumed to be at fixed report
 * IDs/offsets, same as mlink_usb_usage_out/in above - a firmware revision
 * or a different "5G model" device could number/order these differently. */
static const HIDNode_t hid_usage_charging            = 0x00850044UL;
static const HIDNode_t hid_usage_discharging         = 0x00850045UL;
static const HIDNode_t hid_usage_ac_present          = 0x008500D0UL;
static const HIDNode_t hid_usage_below_rcl           = 0x00850042UL;
static const HIDNode_t hid_usage_remaining_capacity  = 0x00850066UL;
static const HIDNode_t hid_usage_runtime_to_empty    = 0x00850068UL;

typedef struct {
	int report_id;	/* 0 = not found on this device */
	int offset;	/* bit offset within the report (excludes the leading Report ID byte) */
	int size;	/* bit size */
} hid_fallback_field_t;

static hid_fallback_field_t ff_charging;
static hid_fallback_field_t ff_discharging;
static hid_fallback_field_t ff_ac_present;
static hid_fallback_field_t ff_below_rcl;
static hid_fallback_field_t ff_remaining_capacity;
static hid_fallback_field_t ff_runtime_to_empty;

/* Latest opportunistically-decoded fallback snapshot. fb_last_update==0
 * means "nothing decoded yet this session". */
static int fb_ac_present = 0;
static int fb_discharging = 0;
static int fb_below_rcl = 0;
static long fb_battery_charge = -1;
static long fb_battery_runtime = -1;
static time_t fb_last_update = 0;

/* Confirmed live: Output/Input report Byte Length 64 (1 Report ID byte +
 * 63 bytes of value data, BitSize=8 Count=63 on both sides). */
#define MLINK_USB_REPORT_PAYLOAD_LEN	63U
#define MLINK_USB_REPORT_TOTAL_LEN	(1U + MLINK_USB_REPORT_PAYLOAD_LEN)

/* The decompiled Windows driver used a 400ms timeout for Output report
 * writes (ApcUsb_ul.dll, writeMultiByteMessage/writeSingleByteCommand);
 * kept a bit more generous here since we are not racing a UI. */
#define MLINK_USB_WRITE_TIMEOUT_MS	1000U

static usb_dev_handle *udev = NULL;
static USBDevice_t curDevice;
static USBDeviceMatcher_t *regex_matcher = NULL;
static usb_communication_subdriver_t *comm_driver = &usb_subdriver;

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
/* Always-outstanding async interrupt-IN listener, serviced by a dedicated
 * pump thread. One libusb_transfer is kept permanently submitted; its
 * callback (which runs on the pump thread) stashes completed reports here
 * and immediately resubmits itself. See the file header comment for the
 * full design history/rationale. */
#define MLINK_USB_ASYNC_QUEUE_LEN	8U

typedef struct {
	unsigned char data[MLINK_USB_REPORT_TOTAL_LEN];
	size_t len;
} microlink_async_report_t;

/* The transfer's buffer is heap-allocated per instance (not a shared static
 * array) - see microlink_usb_async_stop()'s "abandoned" path for why that
 * matters: a transfer libusb hasn't confirmed as cancelled/completed must
 * never be freed out from under it, so an abandoned one is left to free
 * itself (buffer included) whenever its callback eventually does fire. If
 * that buffer were a shared static array, a *new* listener started in the
 * meantime would already be using it for an unrelated transfer. */
static struct libusb_transfer *async_xfer = NULL;
static int async_xfer_active = 0;	/* 1 while a transfer is submitted/outstanding */

/* Everything above, plus the queue below and the fb_* fallback-decode
 * globals back in microlink_usb_try_decode_fallback()'s section, is now
 * genuinely touched from two threads (the pump thread's callback, and the
 * main thread's get_char()/flush_io()/get_hid_fallback()) and must go
 * through this lock. async_cond is signalled whenever the callback adds a
 * report, so get_char() can block on it instead of polling. */
static pthread_mutex_t async_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t async_cond = PTHREAD_COND_INITIALIZER;

static microlink_async_report_t async_queue[MLINK_USB_ASYNC_QUEUE_LEN];
static unsigned int async_queue_head = 0;	/* next slot to pop */
static unsigned int async_queue_count = 0;	/* valid entries currently queued */

/* The pump thread's only job: keep libusb's event loop serviced so the
 * outstanding transfer above actually gets reaped and resubmitted promptly
 * instead of only when microlink_usb_get_char() happens to run. */
static pthread_t async_pump_tid;
static volatile int async_pump_stop = 0;

/* Defined further down (after microlink_usb_try_decode_fallback(), which
 * the transfer callback calls); forward-declared so open/close/reset can
 * call them without reordering the whole file. */
static int microlink_usb_async_start(void);
static void microlink_usb_async_stop(void);
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

static unsigned char in_report[MLINK_USB_REPORT_TOTAL_LEN];
static size_t in_report_len = 0;	/* bytes valid in in_report (0 = empty) */
static size_t in_report_pos = 0;	/* next unconsumed index */

static usb_device_id_t apcmicrolink_usb_device_table[] = {
	/* SCL500RMI1UC, confirmed live (VID/PID + product string
	 * "Smart-UPS 500 FW:UPS 15.6 / ID=1036"). Also already recognized
	 * by apc-hid.c's generic apc_usb_device_table ("various 5G models") -
	 * expected overlap, same as apc_modbus vs. usbhid-ups for several
	 * Smart-UPS models; the user picks whichever driver suits them. */
	{ USB_DEVICE(APC_VENDORID, 0x0003), NULL },

	/* Terminating entry */
	{ 0, 0, NULL }
};

static int microlink_usb_match(USBDevice_t *device, void *privdata)
{
	NUT_UNUSED_VARIABLE(privdata);

	switch (is_usb_device_supported(apcmicrolink_usb_device_table, device))
	{
	case SUPPORTED:
		return 1;

	case POSSIBLY_SUPPORTED:
	case NOT_SUPPORTED:
	default:
		return 0;
	}
}

static USBDeviceMatcher_t microlink_usb_device_matcher = {
	&microlink_usb_match,
	NULL,
	NULL
};

/* Called by comm_driver->open_dev() once a candidate device's HID report
 * descriptor has been fetched. Parse it and pick out the Report IDs behind
 * our two vendor-page usages, exactly as apc_modbus.c's
 * _apc_modbus_usb_callback() does for its own pair of usages. */
static int microlink_usb_report_callback(usb_dev_handle *arg_udev, USBDevice_t *hd,
	usb_ctrl_charbuf rdbuf, usb_ctrl_charbufsize rdlen)
{
	HIDDesc_t *hid_desc;
	size_t i;

	NUT_UNUSED_VARIABLE(arg_udev);
	NUT_UNUSED_VARIABLE(hd);

	mlink_report_out = 0;
	mlink_report_in = 0;

	memset(&ff_charging, 0, sizeof(ff_charging));
	memset(&ff_discharging, 0, sizeof(ff_discharging));
	memset(&ff_ac_present, 0, sizeof(ff_ac_present));
	memset(&ff_below_rcl, 0, sizeof(ff_below_rcl));
	memset(&ff_remaining_capacity, 0, sizeof(ff_remaining_capacity));
	memset(&ff_runtime_to_empty, 0, sizeof(ff_runtime_to_empty));
	fb_last_update = 0;

	if (rdbuf == NULL || rdlen <= 0) {
		upsdebugx(1, "microlink_usb: no HID report descriptor available");
		return -1;
	}

	hid_desc = Parse_ReportDesc(rdbuf, rdlen);
	if (!hid_desc) {
		upsdebug_with_errno(1, "microlink_usb: failed to parse HID report descriptor");
		return -1;
	}

	for (i = 0; i < hid_desc->nitems; i++) {
		HIDData_t *item = &hid_desc->item[i];
		HIDNode_t usage = item->Path.Node[item->Path.Size - 1];
		hid_fallback_field_t *target = NULL;

		if (usage == mlink_usb_usage_out) {
			mlink_report_out = item->ReportID;
			continue;
		}
		if (usage == mlink_usb_usage_in) {
			mlink_report_in = item->ReportID;
			continue;
		}

		/* Only the autonomous Input variant is useful here - the
		 * duplicate Feature-report entries for the same usage would
		 * need an explicit GET_REPORT control transfer we never send. */
		if (item->Type != ITEM_INPUT) {
			continue;
		}

		if (usage == hid_usage_charging) {
			target = &ff_charging;
		} else if (usage == hid_usage_discharging) {
			target = &ff_discharging;
		} else if (usage == hid_usage_ac_present) {
			target = &ff_ac_present;
		} else if (usage == hid_usage_below_rcl) {
			target = &ff_below_rcl;
		} else if (usage == hid_usage_remaining_capacity) {
			target = &ff_remaining_capacity;
		} else if (usage == hid_usage_runtime_to_empty) {
			target = &ff_runtime_to_empty;
		}

		if (target != NULL) {
			target->report_id = item->ReportID;
			target->offset = item->Offset;
			target->size = item->Size;
		}
	}

	if (ff_ac_present.report_id != 0 && ff_discharging.report_id != 0) {
		upsdebugx(1, "microlink_usb: HID PDC status fallback available "
			"(PresentStatus on Report 0x%02X)", (unsigned int)ff_ac_present.report_id);
	} else {
		upsdebugx(1, "microlink_usb: HID PDC status fallback not available on this device "
			"(ACPresent/Discharging usages not found)");
	}

	Free_ReportDesc(hid_desc);

	if (mlink_report_out == 0 || mlink_report_in == 0) {
		upsdebugx(1, "microlink_usb: Microlink USB HID tunnel (vendor page 0xFF86, "
			"usages 0xFC/0xFD) not found on this device");
		return -1;
	}

	upsdebugx(1, "microlink_usb: found HID tunnel: Output Report 0x%02X, Input Report 0x%02X",
		(unsigned int)mlink_report_out, (unsigned int)mlink_report_in);

	return 1;
}

void microlink_usb_addvars(void)
{
	nut_usb_addvars();
}

int microlink_usb_open(void)
{
	char *regex_array[USBMATCHER_REGEXP_ARRAY_LIMIT];
	int ret;

	warn_if_bad_usb_port_filename(device_path);

	regex_array[0] = getval("vendorid");
	regex_array[1] = getval("productid");
	regex_array[2] = getval("vendor");
	regex_array[3] = getval("product");
	regex_array[4] = getval("serial");
	regex_array[5] = getval("bus");
	regex_array[6] = getval("device");
#if (defined WITH_USB_BUSPORT) && (WITH_USB_BUSPORT)
	regex_array[7] = getval("busport");
#else
	if (getval("busport")) {
		upslogx(LOG_WARNING, "\"busport\" is configured for the device, but is not "
			"actually handled by current build combination of NUT and libusb (ignored)");
	}
#endif

	ret = USBNewRegexMatcher(&regex_matcher, regex_array, REG_ICASE | REG_EXTENDED);
	if (ret < 0) {
		fatal_with_errno(EXIT_FAILURE, "USBNewRegexMatcher");
	} else if (ret) {
		fatalx(EXIT_FAILURE, "invalid regular expression: %s", regex_array[ret]);
	}

	regex_matcher->next = &microlink_usb_device_matcher;

	ret = comm_driver->open_dev(&udev, &curDevice, regex_matcher, microlink_usb_report_callback);
	if (ret < 1) {
		fatalx(EXIT_FAILURE, "apcmicrolink: no matching USB Microlink UPS found");
	}

	dstate_setinfo("ups.vendorid", "%04x", curDevice.VendorID);
	dstate_setinfo("ups.productid", "%04x", curDevice.ProductID);

	upsdebugx(1, "microlink_usb: opened %s/%s (USB %04x:%04x)",
		curDevice.Vendor ? curDevice.Vendor : "unknown",
		curDevice.Product ? curDevice.Product : "unknown",
		curDevice.VendorID, curDevice.ProductID);

	in_report_len = 0;
	in_report_pos = 0;

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
	if (!microlink_usb_async_start()) {
		upsdebugx(1, "microlink_usb: continuous async listener unavailable, "
			"falling back to per-call synchronous interrupt-IN reads");
	}
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

	return 1;
}

void microlink_usb_close(void)
{
#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
	microlink_usb_async_stop();
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

	if (udev) {
		comm_driver->close_dev(udev);
		udev = NULL;
	}

	USBFreeRegexMatcher(regex_matcher);
	regex_matcher = NULL;

	free(curDevice.Vendor);
	free(curDevice.Product);
	free(curDevice.Serial);
	free(curDevice.Bus);
	free(curDevice.Device);
#if (defined WITH_USB_BUSPORT) && (WITH_USB_BUSPORT)
	free(curDevice.BusPort);
#endif
	memset(&curDevice, 0, sizeof(curDevice));

	in_report_len = 0;
	in_report_pos = 0;
}

int microlink_usb_reset_and_reopen(void)
{
	int ret;

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
	/* Must cancel the outstanding async transfer before resetting/closing
	 * the handle it's submitted against - leaving it dangling here would
	 * either leak it or have its completion callback fire against a udev
	 * that's already gone. */
	microlink_usb_async_stop();
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

	if (udev) {
		/* Send USB bus reset. The handle is invalid afterward regardless
		 * of the return value -- close it unconditionally. usb_reset()
		 * is NUT's usb-common.h abstraction (libusb_reset_device on
		 * libusb-1.0, usb_reset on libusb-0.1); calling libusb_reset_device
		 * directly breaks NUT_USB_VARIANT=0.1 builds. */
		usb_reset(udev);
		comm_driver->close_dev(udev);
		udev = NULL;
	}

	/* Discard old device strings; open_dev() will re-populate them. */
	free(curDevice.Vendor);
	free(curDevice.Product);
	free(curDevice.Serial);
	free(curDevice.Bus);
	free(curDevice.Device);
#if (defined WITH_USB_BUSPORT) && (WITH_USB_BUSPORT)
	free(curDevice.BusPort);
#endif
	memset(&curDevice, 0, sizeof(curDevice));
	in_report_len = 0;
	in_report_pos = 0;

	/* Give the device time to complete re-enumeration before opening. */
	sleep(2);

	/* Re-open using the still-valid regex_matcher (never freed here). */
	ret = comm_driver->open_dev(&udev, &curDevice, regex_matcher,
		microlink_usb_report_callback);
	if (ret < 1) {
		udev = NULL;
		return 0;
	}

	upsdebugx(1, "microlink_usb: reset and reopened %s/%s (USB %04x:%04x)",
		curDevice.Vendor ? curDevice.Vendor : "unknown",
		curDevice.Product ? curDevice.Product : "unknown",
		curDevice.VendorID, curDevice.ProductID);

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
	if (!microlink_usb_async_start()) {
		upsdebugx(1, "microlink_usb: continuous async listener unavailable after "
			"reset, falling back to per-call synchronous interrupt-IN reads");
	}
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

	return 1;
}

/* A timeout of 0 to libusb_interrupt_transfer() means "wait forever", not
 * "don't block" - confirmed the hard way against real hardware, where a
 * 0ms drain call could stall this function (and everything after it) for
 * however long the device's interrupt pipe happened to be idle, since
 * this device also pushes unrelated Input reports on the same pipe only
 * every 100-200ms (see apcmicrolink-usb.c's header comment) and the pipe
 * can be briefly, genuinely empty. Use a short real timeout instead, and
 * cap the number of drained reports as a defensive bound. */
#define MLINK_USB_FLUSH_TIMEOUT_MS	20U
#define MLINK_USB_FLUSH_MAX_REPORTS	32U

void microlink_usb_flush_io(void)
{
	unsigned char discard[MLINK_USB_REPORT_TOTAL_LEN];
	int ret;
	unsigned int drained;

	in_report_len = 0;
	in_report_pos = 0;

	if (!udev) {
		return;
	}

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
	if (async_xfer_active) {
		/* The async listener already owns the interrupt-IN endpoint - a
		 * second, synchronous get_interrupt() call here would race it.
		 * The dedicated pump thread is already servicing the event loop
		 * continuously, so just drop whatever's queued under the lock;
		 * this function must never call libusb_handle_events*() itself -
		 * that would make it a second caller of the event loop, the exact
		 * pattern that caused the regression in the reverted two-thread
		 * design (see the file header comment). */
		pthread_mutex_lock(&async_lock);
		async_queue_head = 0;
		async_queue_count = 0;
		pthread_mutex_unlock(&async_lock);
		return;
	}
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

	for (drained = 0; drained < MLINK_USB_FLUSH_MAX_REPORTS; drained++) {
		ret = comm_driver->get_interrupt(udev, (usb_ctrl_charbuf)discard,
			(usb_ctrl_charbufsize)sizeof(discard),
			(usb_ctrl_timeout_msec)MLINK_USB_FLUSH_TIMEOUT_MS);
		if (ret <= 0) {
			break;
		}
	}
}

/* Confirmed live on real hardware: the Linux kernel's own generic "usbhid"
 * driver can reclaim this device's interface out from under an already-open,
 * already-claimed libusb handle - observed once, apparently following a USB
 * reset/re-enumeration event this driver has no visibility into. Once that
 * happens, every USBDEVFS_SUBMITURB this process makes is rejected by the
 * kernel with EBUSY (surfaces here as LIBUSB_ERROR_BUSY) until the process
 * is restarted - and because that failure returns near-instantly, unlike a
 * real timeout, nothing above this file paces the resulting retries: one
 * observed incident spun at ~14,000 failed submissions/sec for 30+ minutes
 * straight, saturating a CPU core and, via dmesg's own "did not claim
 * interface" message at the same rate, completely overwriting the kernel
 * ring buffer before the actual triggering event could ever be identified.
 *
 * A permanent udev rule that unbinds usbhid from this VID:PID (installed
 * outside this source tree, e.g. as a distro packaging step) avoids this in
 * practice. This handler is defense in depth for that rule being absent, or
 * for some other cause of the same kernel-level symptom: back off hard
 * instead of spinning, and log loudly (not upsdebugx, which is invisible
 * without -D) but rate-limited, so a recurrence is visible in syslog
 * without flooding it or dmesg the way the uncaught case did. */
#define MLINK_USB_BUSY_BACKOFF_USEC	1000000U
#define MLINK_USB_BUSY_LOG_EVERY	30U

static void microlink_usb_handle_busy(const char *context)
{
	static unsigned long busy_count = 0;

	busy_count++;

	if (busy_count == 1 || (busy_count % MLINK_USB_BUSY_LOG_EVERY) == 0) {
		upslogx(LOG_WARNING, "microlink_usb: %s: USBDEVFS_SUBMITURB rejected "
			"with EBUSY (occurrence %lu) - another driver (commonly the "
			"kernel's own \"usbhid\") may have reclaimed this device's USB "
			"interface out from under this process; check \"lsusb -t\" and "
			"dmesg for a competing driver bound to this device. "
			"Backing off %.1fs before the next attempt instead of retrying "
			"immediately.",
			context, busy_count, (double)MLINK_USB_BUSY_BACKOFF_USEC / 1000000.0);
	}

	usleep(MLINK_USB_BUSY_BACKOFF_USEC);
}

int microlink_usb_send_bytes(const unsigned char *buf, size_t len)
{
	unsigned char raw_buf[MLINK_USB_REPORT_TOTAL_LEN];
	int ret;

	if (!udev || mlink_report_out == 0) {
		return 0;
	}

	if (len > MLINK_USB_REPORT_PAYLOAD_LEN) {
		upsdebugx(1, "microlink_usb: refusing to send a %" PRIuSIZE
			"-byte frame, exceeds the %u-byte USB Output report capacity",
			len, (unsigned int)MLINK_USB_REPORT_PAYLOAD_LEN);
		return 0;
	}

	/* Confirmed against real SCL500RMI1UC hardware: comm_driver->set_report()
	 * (nut_libusb_set_report(), HID class SET_REPORT control transfer with
	 * Report Type Output 0x02<<8 instead of its hardcoded Feature 0x03<<8)
	 * was tried first, and while the control transfer itself succeeds at
	 * the USB level (no stall, no error), the device never actually reacts
	 * to it - no reply ever appears on the Input Report 0x89 channel,
	 * regardless of init byte or how long you wait. Switching to a genuine
	 * interrupt-OUT write on the Output endpoint (matching the real
	 * Windows driver's behavior) gets an immediate, correctly-framed,
	 * checksum-valid response stream. So this device's raw HID tunnel
	 * genuinely requires interrupt-OUT, not just a HID-spec-valid control
	 * transfer to the same Report ID - apparently the firmware's tunnel
	 * implementation only watches the interrupt endpoint's hardware FIFO,
	 * not the control endpoint. */
	raw_buf[0] = (unsigned char)mlink_report_out;
	memset(raw_buf + 1, 0, sizeof(raw_buf) - 1);
	memcpy(raw_buf + 1, buf, len);

	ret = usb_interrupt_write(udev,
		USB_ENDPOINT_OUT + usb_subdriver.hid_ep_out,
		(usb_ctrl_charbuf)raw_buf,
		(int)sizeof(raw_buf),
		(int)MLINK_USB_WRITE_TIMEOUT_MS);

	if (ret == LIBUSB_ERROR_PIPE) {
		upsdebugx(2, "microlink_usb: interrupt-OUT write (Output 0x%02X) stalled",
			(unsigned int)mlink_report_out);
		return 0;
	}

	if (ret == LIBUSB_ERROR_BUSY) {
		microlink_usb_handle_busy("interrupt-OUT write");
		return 0;
	}

	if (ret < 0) {
		upsdebugx(1, "microlink_usb: interrupt-OUT write (Output 0x%02X) failed: %s",
			(unsigned int)mlink_report_out, nut_usb_strerror(ret));
		return 0;
	}

	return 1;
}

/* Extract a little-endian, LSB-first-packed bit field from a HID report's
 * data (everything after the leading Report ID byte), matching how
 * Parse_ReportDesc()'s Offset/Size describe fields - confirmed against
 * real captured bytes from this device (e.g. a 32-bit RunTimeToEmpty
 * field at offset 0 decoded correctly as little-endian this way).
 * bit_size is capped to fit in an unsigned long as this is only ever
 * used for <=32-bit fields here. */
static unsigned long hid_extract_bits(const unsigned char *data, size_t data_len,
	int bit_offset, int bit_size)
{
	unsigned long value = 0;
	int i;

	if (bit_offset < 0 || bit_size <= 0 || bit_size > 32) {
		return 0;
	}

	for (i = 0; i < bit_size; i++) {
		int bit_pos = bit_offset + i;
		size_t byte_idx = (size_t)(bit_pos / 8);
		int bit_idx = bit_pos % 8;

		if (byte_idx >= data_len) {
			break;
		}
		if ((data[byte_idx] & (1 << bit_idx)) != 0) {
			value |= (1UL << i);
		}
	}

	return value;
}

/* Opportunistically decode the standard-HID-PDC fallback fields if this
 * report happens to be one of them - called on every Input report we see,
 * whether or not it turns out to be our own Microlink tunnel reply, since
 * these arrive autonomously and independently of tunnel health. */
static void microlink_usb_try_decode_fallback(const unsigned char *report, size_t report_len)
{
	int report_id;
	const unsigned char *data;
	size_t data_len;

	if (report_len < 1) {
		return;
	}
	report_id = (int)report[0];
	data = report + 1;
	data_len = report_len - 1;

	if (ff_ac_present.report_id == report_id) {
		fb_ac_present = (int)hid_extract_bits(data, data_len, ff_ac_present.offset, ff_ac_present.size);
	}
	if (ff_discharging.report_id == report_id) {
		fb_discharging = (int)hid_extract_bits(data, data_len, ff_discharging.offset, ff_discharging.size);
	}
	if (ff_below_rcl.report_id == report_id) {
		fb_below_rcl = (int)hid_extract_bits(data, data_len, ff_below_rcl.offset, ff_below_rcl.size);
	}
	if (ff_remaining_capacity.report_id == report_id) {
		fb_battery_charge = (long)hid_extract_bits(data, data_len,
			ff_remaining_capacity.offset, ff_remaining_capacity.size);
	}
	if (ff_runtime_to_empty.report_id == report_id) {
		fb_battery_runtime = (long)hid_extract_bits(data, data_len,
			ff_runtime_to_empty.offset, ff_runtime_to_empty.size);
	}

	if (report_id == ff_ac_present.report_id || report_id == ff_discharging.report_id
	 || report_id == ff_below_rcl.report_id || report_id == ff_remaining_capacity.report_id
	 || report_id == ff_runtime_to_empty.report_id) {
		fb_last_update = time(NULL);
	}
}

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
/* The pump thread's only job: keep libusb's event loop serviced so
 * async_xfer actually gets reaped and resubmitted promptly, independent of
 * whatever the main thread happens to be doing. Nothing else may call
 * libusb_handle_events*() on this context while this thread is running -
 * see the file header comment for why that split matters. */
static void *microlink_usb_async_pump(void *arg)
{
	NUT_UNUSED_VARIABLE(arg);

	while (!async_pump_stop) {
		struct timeval tv;

		tv.tv_sec = 0;
		tv.tv_usec = 50000; /* 50ms - bounds how fast a stop request is noticed */
		libusb_handle_events_timeout_completed(nut_libusb_get_context(), &tv, NULL);
	}

	return NULL;
}

/* Fires from inside libusb_handle_events*() on the pump thread. Stashes a
 * completed report and immediately resubmits the same transfer, so exactly
 * one interrupt-IN request stays outstanding at all times.
 *
 * transfer->user_data doubles as an "abandoned" marker (see
 * microlink_usb_async_stop()): non-NULL means this driver gave up owning
 * this transfer without waiting for libusb to confirm its cancellation -
 * libusb forbids freeing a transfer before its completion callback has
 * actually fired, so an abandoned one frees itself (and its buffer) right
 * here, whenever that eventually happens, instead of ever resubmitting. */
static void LIBUSB_CALL microlink_usb_async_cb(struct libusb_transfer *transfer)
{
	int abandoned = (transfer->user_data != NULL);

	if (!abandoned && transfer->status == LIBUSB_TRANSFER_COMPLETED && transfer->actual_length > 0) {
		size_t copy_len = (size_t)transfer->actual_length;

		if (copy_len > MLINK_USB_REPORT_TOTAL_LEN) {
			copy_len = MLINK_USB_REPORT_TOTAL_LEN;
		}

		/* microlink_usb_try_decode_fallback() writes the fb_* globals that
		 * microlink_usb_get_hid_fallback() reads on the main thread - both
		 * now go through async_lock. Decode happens immediately on receipt,
		 * same as the old synchronous path did, regardless of whether this
		 * report also turns out to be our own Microlink tunnel reply. */
		pthread_mutex_lock(&async_lock);

		microlink_usb_try_decode_fallback(transfer->buffer, copy_len);

		if (async_queue_count < MLINK_USB_ASYNC_QUEUE_LEN) {
			unsigned int slot = (async_queue_head + async_queue_count) % MLINK_USB_ASYNC_QUEUE_LEN;

			memcpy(async_queue[slot].data, transfer->buffer, copy_len);
			async_queue[slot].len = copy_len;
			async_queue_count++;
			pthread_cond_signal(&async_cond);
		} else {
			upsdebugx(3, "microlink_usb: async read queue full (%u), dropping "
				"incoming report", MLINK_USB_ASYNC_QUEUE_LEN);
		}

		pthread_mutex_unlock(&async_lock);
	}

	if (abandoned) {
		free(transfer->buffer);
		libusb_free_transfer(transfer);
		return;
	}

	switch (transfer->status) {
	case LIBUSB_TRANSFER_CANCELLED:
	case LIBUSB_TRANSFER_NO_DEVICE:
		/* Teardown in progress, or the device is gone - don't resubmit.
		 * microlink_usb_async_stop() owns freeing this transfer/buffer
		 * once it observes async_xfer_active go to 0. */
		pthread_mutex_lock(&async_lock);
		async_xfer_active = 0;
		pthread_mutex_unlock(&async_lock);
		return;
	default:
		break;
	}

	if (libusb_submit_transfer(transfer) != 0) {
		upsdebugx(1, "microlink_usb: failed to resubmit async interrupt-IN "
			"transfer, continuous listener stopped");
		pthread_mutex_lock(&async_lock);
		async_xfer_active = 0;
		pthread_mutex_unlock(&async_lock);
	}
}

/* Start the always-outstanding listener plus its dedicated pump thread.
 * Returns 1 if running (or already was), 0 if it could not be started -
 * callers fall back to per-call synchronous reads in that case, so this is
 * never fatal. */
static int microlink_usb_async_start(void)
{
	int ep_in;
	unsigned char *buf;

	if (!udev) {
		return 0;
	}
	if (async_xfer_active) {
		return 1;
	}

	ep_in = USB_ENDPOINT_IN + usb_subdriver.hid_ep_in;

	/* Heap-allocated per instance, not a shared static array - see the
	 * comment above async_xfer's declaration for why. */
	buf = xmalloc(MLINK_USB_REPORT_TOTAL_LEN);

	async_xfer = libusb_alloc_transfer(0);
	if (!async_xfer) {
		upsdebugx(1, "microlink_usb: libusb_alloc_transfer failed for the "
			"async listener");
		free(buf);
		return 0;
	}

	/* Timeout 0 on an async transfer just means "no timeout on this
	 * submission" (unlike the synchronous API, where 0 means "wait
	 * forever" - see microlink_usb_flush_io()'s header comment for that
	 * pitfall) - exactly what we want here: stay outstanding indefinitely
	 * until data arrives or it's explicitly cancelled. user_data starts
	 * NULL ("owned"); microlink_usb_async_stop() sets it non-NULL to mark
	 * the transfer abandoned if it ever has to walk away without waiting
	 * for a cancellation to confirm. */
	libusb_fill_interrupt_transfer(async_xfer, udev, ep_in,
		buf, (int)MLINK_USB_REPORT_TOTAL_LEN,
		microlink_usb_async_cb, NULL, 0);

	if (libusb_submit_transfer(async_xfer) != 0) {
		upsdebugx(1, "microlink_usb: failed to submit the initial async "
			"interrupt-IN transfer");
		libusb_free_transfer(async_xfer);
		free(buf);
		async_xfer = NULL;
		return 0;
	}

	async_queue_head = 0;
	async_queue_count = 0;
	async_xfer_active = 1;

	async_pump_stop = 0;
	if (pthread_create(&async_pump_tid, NULL, microlink_usb_async_pump, NULL) != 0) {
		upsdebugx(1, "microlink_usb: failed to start the async pump thread, "
			"abandoning the just-submitted transfer and falling back to "
			"synchronous reads");
		/* Nobody will service this context's event loop until some future
		 * synchronous call incidentally does (libusb's sync API pumps the
		 * same shared context while waiting on its own transfer) - request
		 * cancellation now so it stops competing for the endpoint as soon
		 * as that happens, then walk away exactly like the timeout path in
		 * microlink_usb_async_stop() below. */
		libusb_cancel_transfer(async_xfer);
		async_xfer->user_data = (void *)1;
		async_xfer = NULL;
		async_xfer_active = 0;
		async_queue_head = 0;
		async_queue_count = 0;
		return 0;
	}

	upsdebugx(2, "microlink_usb: continuous async interrupt-IN listener started");
	return 1;
}

/* Stop the pump thread first - once it has actually exited, this function
 * is the only thing left that might touch libusb's event loop, so the
 * cancel-and-wait dance below is safely single-threaded again.
 *
 * Cancel the outstanding transfer, if any, and wait (bounded) for libusb to
 * actually confirm the cancellation before freeing it - freeing a transfer
 * libusb hasn't yet reported as complete/cancelled is undefined behavior
 * (observed live: a "usbi_mutex_lock" assertion crash during a USB reset,
 * from an earlier version of this function that freed unconditionally after
 * the wait timed out). If the bound is hit - realistically only when the
 * device is already too wedged to answer a cancel request, i.e. exactly the
 * situation that leads here (about to force a USB reset) - mark the
 * transfer abandoned via user_data and let go of it entirely: the callback
 * above frees it (and its buffer) itself whenever libusb eventually does
 * complete it, however long that takes (serviced by whichever future call -
 * sync or async - next touches this context's event loop). This function
 * must never touch an abandoned transfer again after that. */
static void microlink_usb_async_stop(void)
{
	int i;

	if (!async_xfer) {
		return;
	}

	async_pump_stop = 1;
	pthread_join(async_pump_tid, NULL);

	if (async_xfer_active) {
		libusb_cancel_transfer(async_xfer);

		for (i = 0; i < 50 && async_xfer_active; i++) {
			struct timeval tv;

			tv.tv_sec = 0;
			tv.tv_usec = 20000;
			libusb_handle_events_timeout_completed(nut_libusb_get_context(), &tv, NULL);
		}

		if (async_xfer_active) {
			upsdebugx(1, "microlink_usb: async transfer did not confirm "
				"cancellation in time, abandoning it (it will free itself "
				"once libusb eventually completes it)");
			async_xfer->user_data = (void *)1;
			async_xfer = NULL;
			async_xfer_active = 0;
			async_queue_head = 0;
			async_queue_count = 0;
			return;
		}
	}

	free(async_xfer->buffer);
	libusb_free_transfer(async_xfer);
	async_xfer = NULL;
	async_queue_head = 0;
	async_queue_count = 0;
}
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

int microlink_usb_get_hid_fallback(int max_age_sec,
	int *ac_present, int *discharging, int *below_rcl,
	long *battery_charge, long *battery_runtime)
{
	if (ff_ac_present.report_id == 0 || ff_discharging.report_id == 0) {
		return 0;
	}

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
	pthread_mutex_lock(&async_lock);
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

	if (fb_last_update == 0 || max_age_sec < 0
	 || difftime(time(NULL), fb_last_update) > (double)max_age_sec) {
#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
		pthread_mutex_unlock(&async_lock);
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */
		return 0;
	}

	if (ac_present != NULL) {
		*ac_present = fb_ac_present;
	}
	if (discharging != NULL) {
		*discharging = fb_discharging;
	}
	if (below_rcl != NULL) {
		*below_rcl = fb_below_rcl;
	}
	if (battery_charge != NULL) {
		*battery_charge = (ff_remaining_capacity.report_id != 0) ? fb_battery_charge : -1;
	}
	if (battery_runtime != NULL) {
		*battery_runtime = (ff_runtime_to_empty.report_id != 0) ? fb_battery_runtime : -1;
	}

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
	pthread_mutex_unlock(&async_lock);
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */

	return 1;
}

int microlink_usb_hid_fallback_supported(void)
{
	return (ff_ac_present.report_id != 0 && ff_discharging.report_id != 0);
}

/* Original per-call synchronous implementation - issues one fresh
 * libusb_interrupt_transfer() (via comm_driver->get_interrupt()) and waits
 * up to d_usec for it to complete. Used as-is on non-libusb-1.0 builds, and
 * as the fallback if the async listener (below) couldn't be started. */
static int microlink_usb_get_char_sync(unsigned char *ch, long d_usec)
{
	int ret;
	usb_ctrl_timeout_msec timeout_ms;

	if (!udev || mlink_report_in == 0) {
		return -1;
	}

	if (in_report_pos < in_report_len) {
		*ch = in_report[in_report_pos++];
		return 1;
	}

	if (d_usec < 0) {
		d_usec = 0;
	}
	timeout_ms = (usb_ctrl_timeout_msec)((d_usec / 1000L) + ((d_usec % 1000L) ? 1L : 0L));

	ret = comm_driver->get_interrupt(udev, (usb_ctrl_charbuf)in_report,
		(usb_ctrl_charbufsize)sizeof(in_report), timeout_ms);

	if (ret == LIBUSB_ERROR_BUSY) {
		microlink_usb_handle_busy("interrupt-IN read");
		in_report_len = 0;
		in_report_pos = 0;
		return -1;
	}

	if (ret < 0) {
		in_report_len = 0;
		in_report_pos = 0;
		return -1;
	}

	/* The interrupt IN endpoint can also carry other Input reports this
	 * device pushes (e.g. the mirrored 0x84:0x24 scalars) - ignore
	 * anything that is not our row-push channel rather than feeding
	 * foreign report bytes into the Microlink byte stream. Before
	 * discarding, though: some of those "other" reports are exactly the
	 * standard-HID-PDC fallback fields, which keep arriving
	 * independent of whether the tunnel itself is responding - worth
	 * decoding regardless of what this specific read call was for. */
	if (ret >= 1) {
		microlink_usb_try_decode_fallback(in_report, (size_t)ret);
	}

	if (ret < 2 || (int)in_report[0] != mlink_report_in) {
		in_report_len = 0;
		in_report_pos = 0;
		return 0;
	}

	in_report_len = (size_t)ret;
	in_report_pos = 1; /* skip the leading Report ID byte */

	*ch = in_report[in_report_pos++];
	return 1;
}

#if WITH_LIBUSB_1_0 && defined(HAVE_PTHREAD)
/* Mirrors ser_get_char()'s contract exactly, same as the synchronous
 * version above: return at most one report's worth of decision per call
 * (1 with *ch filled, 0 on timeout or a non-matching report, negative on
 * hard error) - the caller (microlink_receive_once()) already loops on 0
 * itself. The difference is where the wait happens: instead of issuing a
 * fresh interrupt-IN request and blocking on it here, this waits on
 * async_cond for the dedicated pump thread to deliver a report into the
 * always-outstanding listener's queue - including one that completed
 * *before* this call even started, e.g. during the caller's multi-second
 * sleep between retries, which the pump thread already reaped in the
 * background. This function must never call libusb_handle_events*()
 * itself - only the pump thread may touch the event loop. */
int microlink_usb_get_char(unsigned char *ch, long d_usec)
{
	struct timespec deadline;
	microlink_async_report_t slot;
	size_t copy_len;

	if (!async_xfer_active) {
		return microlink_usb_get_char_sync(ch, d_usec);
	}

	if (!udev || mlink_report_in == 0) {
		return -1;
	}

	if (in_report_pos < in_report_len) {
		*ch = in_report[in_report_pos++];
		return 1;
	}

	if (d_usec < 0) {
		d_usec = 0;
	}

	/* pthread_cond_timedwait() takes an absolute deadline on the system
	 * (CLOCK_REALTIME) clock by default - no portable way to request
	 * CLOCK_MONOTONIC here without pthread_condattr_setclock(), a POSIX
	 * extension not available everywhere this codebase targets. */
	clock_gettime(CLOCK_REALTIME, &deadline);
	deadline.tv_sec += d_usec / 1000000L;
	deadline.tv_nsec += (d_usec % 1000000L) * 1000L;
	if (deadline.tv_nsec >= 1000000000L) {
		deadline.tv_sec++;
		deadline.tv_nsec -= 1000000000L;
	}

	pthread_mutex_lock(&async_lock);

	while (async_queue_count == 0) {
		if (pthread_cond_timedwait(&async_cond, &async_lock, &deadline) != 0) {
			/* Timed out (or some other wait error) - no report showed up
			 * within the caller's budget. */
			pthread_mutex_unlock(&async_lock);
			return 0;
		}
	}

	slot = async_queue[async_queue_head];
	async_queue_head = (async_queue_head + 1) % MLINK_USB_ASYNC_QUEUE_LEN;
	async_queue_count--;

	pthread_mutex_unlock(&async_lock);

	copy_len = (slot.len > sizeof(in_report)) ? sizeof(in_report) : slot.len;
	memcpy(in_report, slot.data, copy_len);

	if (copy_len < 2 || (int)in_report[0] != mlink_report_in) {
		in_report_len = 0;
		in_report_pos = 0;
		return 0;
	}

	in_report_len = copy_len;
	in_report_pos = 1; /* skip the leading Report ID byte */

	*ch = in_report[in_report_pos++];
	return 1;
}
#else /* !(WITH_LIBUSB_1_0 && HAVE_PTHREAD) */
int microlink_usb_get_char(unsigned char *ch, long d_usec)
{
	return microlink_usb_get_char_sync(ch, d_usec);
}
#endif /* WITH_LIBUSB_1_0 && HAVE_PTHREAD */
