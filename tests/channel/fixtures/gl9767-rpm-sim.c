/*
 * Replays linux-omarchy's 0570 (GL9767 SD reader runtime PM, #226, #418)
 * against stubs: the patch's own functions, extracted by
 * tests/channel/linux-omarchy-gl9767-rpm.sh into gl9767.c, run under a small
 * model of the runtime-PM core and the mmc core, with time in ms (HZ 1000).
 *
 * The model of the reader: an empty slot is quiet in D3, except for a "storm"
 * window, in which every runtime suspend is followed 20 ms later by a PME
 * wakeup that finds no card. That is what the G16 showed right after a card
 * was removed (8 such wakes within a second). A wakeup resumes the host
 * unclaimed; the PM core then suspends it again at once (a PME resume does not
 * mark it busy). A rescan queued with mmc_detect_change() runs 200 ms later:
 * a claim (resuming the host if needed) and a release. card_event runs only
 * from the card insert/remove interrupt (sdhci_thread_irq), which fires only
 * in D0: mmc_rescan calls it only for slot-gpio card detect, which the GL9767
 * doesn't use.
 *
 * Prints one "name value" line per scenario; the shell test checks them.
 */
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

typedef unsigned int u32;
typedef unsigned char u8;
#define HZ 1000
#define MSEC_PER_SEC 1000U
#define SDHCI_INT_STATUS 0x30
#define SDHCI_INT_ENABLE 0x34
#define SDHCI_PRESENT_STATE 0x24
#define SDHCI_WAKE_UP_CONTROL 0x2b
#define SDHCI_INT_CARD_INSERT 0x40
#define SDHCI_CARD_PRESENT 0x10000
#define SDHCI_CD_STABLE 0x20000
#define SDHCI_WAKE_ON_INSERT 0x02
#define MMC_POWER_OFF 0
#define MMC_POWER_ON 2
#define READ_ONCE(x) (x)
#define __stringify_1(x) #x
#define __stringify(x) __stringify_1(x)
#define time_before(a, b) ((long)((a) - (b)) < 0)
#define time_after(a, b) time_before(b, a)
#define msecs_to_jiffies(m) ((unsigned long)(m))
#define jiffies_to_msecs(j) ((unsigned int)(j))
#define min(a, b) ((a) < (b) ? (a) : (b))
#define container_of(p, t, m) ((t *)((char *)(p) - offsetof(t, m)))
#define dev_dbg(...) ((void)0)
#define dev_info(dev, ...) (infos++)

struct device { int x; };
struct work_struct { int x; };
struct delayed_work { struct work_struct work; void (*fn)(struct work_struct *); long due; };
#define to_delayed_work(w) container_of(w, struct delayed_work, work)
#define INIT_DELAYED_WORK(dw, f) ((dw)->fn = (f), (dw)->due = -1)
#define system_power_efficient_wq NULL
struct mmc_ios { int power_mode; };
struct mmc_host { int claimed; struct mmc_ios ios; };
struct sdhci_host { struct mmc_host *mmc; bool runtime_suspended; u32 ier; };
struct pci_dev { struct device dev; };
struct sdhci_pci_chip;
struct sdhci_pci_slot;

static unsigned long jiffies;
static u32 reg_present, reg_status;
static int infos, mmio_suspended, rescan_at = -1, resumes;
static long autosuspend_at = -1;	/* a runtime suspend the PM core will try */

#include "gl9767.c"

struct sdhci_pci_slot { struct sdhci_pci_chip *chip; struct sdhci_host *host; struct gl9767_host gl; };
struct sdhci_pci_chip { struct sdhci_pci_slot *slots[1]; struct pci_dev *pdev; };

static struct gl9767_host *sdhci_pci_priv(struct sdhci_pci_slot *s) { return &s->gl; }
static bool pci_dev_run_wake(struct pci_dev *p) { (void)p; return true; }
static void pm_runtime_mark_last_busy(struct device *d) { (void)d; }
static void pm_request_autosuspend(struct device *d) { (void)d; autosuspend_at = jiffies + 50; }
static bool mod_delayed_work(void *wq, struct delayed_work *dw, unsigned long delay)
{
	(void)wq; dw->due = (long)(jiffies + delay); return true;
}
static void cancel_delayed_work_sync(struct delayed_work *dw) { dw->due = -1; }

static struct mmc_host mmc;
static struct sdhci_host host = { &mmc, false, 0 };
static struct pci_dev pdev;
static struct sdhci_pci_chip chip;
static struct sdhci_pci_slot slot = { &chip, &host, { 0 } };

static struct sdhci_pci_slot *sdhci_priv(struct sdhci_host *h) { (void)h; return &slot; }
static bool d3;	/* the function is in D3: its registers don't answer */
static void mmio(void) { if (d3) mmio_suspended++; }
static u32 sdhci_readl(struct sdhci_host *h, int r)
{
	(void)h; mmio(); return r == SDHCI_INT_STATUS ? reg_status : reg_present;
}
static void sdhci_writel(struct sdhci_host *h, u32 v, int r) { (void)h; (void)v; (void)r; mmio(); }
static u8 sdhci_readb(struct sdhci_host *h, int r) { (void)h; (void)r; mmio(); return 0; }
static void sdhci_writeb(struct sdhci_host *h, u8 v, int r) { (void)h; (void)v; (void)r; mmio(); }
static void sdhci_gl9767_set_card_detect_debounce_time(struct sdhci_host *h) { (void)h; mmio(); }
static void gl9767_hw_setting(struct sdhci_pci_slot *s) { (void)s; }
static void gl9767_vendor_init(struct sdhci_host *h) { (void)h; }
static void sdhci_runtime_suspend_host(struct sdhci_host *h) { h->runtime_suspended = true; }
static void sdhci_runtime_resume_host(struct sdhci_host *h, int x) { (void)x; h->runtime_suspended = false; reg_status = 0; }
static void mmc_detect_change(struct mmc_host *m, unsigned long d)
{
	(void)m; if (rescan_at < 0) rescan_at = (int)(jiffies + d);
}

#include "gl9767-fns.c"

/* ---------------------------------------------------------------- model */
static bool suspended;
static long storm_until, last_suspend, wake_at = -1;
static u32 storm_status;	/* what a storm wakeup leaves latched */

static void do_resume(int claimed)
{
	mmc.claimed = claimed;
	d3 = false;	/* the PCI core brings it to D0 before the callback */
	gl9767_runtime_resume(&chip);
	suspended = false;
	resumes++;
	mmc.claimed = 0;
}

static void try_suspend(void)
{
	int r = gl9767_runtime_suspend(&chip);

	autosuspend_at = -1;
	if (r == -EAGAIN) {
		autosuspend_at = jiffies + 50;
	} else if (r == 0) {
		suspended = true;
		d3 = true;
		last_suspend = jiffies;
		if (time_before(jiffies, storm_until))
			wake_at = jiffies + 20;
	}
}

static void run(long ms)
{
	long end = jiffies + ms;

	for (; time_before(jiffies, end); jiffies++) {
#ifdef HAVE_HOLD
		struct delayed_work *dw = &slot.gl.hold_end;

		if (dw->due >= 0 && (long)jiffies >= dw->due) {
			dw->due = -1;
			dw->fn(&dw->work);
		}
#endif
		if (suspended && wake_at >= 0 && (long)jiffies >= wake_at) {
			wake_at = -1;
			reg_status = storm_status;
			do_resume(0);
			autosuspend_at = jiffies;	/* last_busy is old */
		}
		if (rescan_at >= 0 && (long)jiffies >= rescan_at) {
			rescan_at = -1;
			if (suspended)
				do_resume(1);
			autosuspend_at = jiffies + 50;	/* release */
		}
		if (!suspended && autosuspend_at >= 0 && (long)jiffies >= autosuspend_at)
			try_suspend();
	}
}

static void boot(void)
{
	memset(&slot.gl, 0, sizeof(slot.gl));
	chip.slots[0] = &slot;
	chip.pdev = &pdev;
	jiffies = 1000000;
	suspended = false; d3 = false; wake_at = -1; rescan_at = -1; storm_until = jiffies;
	storm_status = 0; infos = 0; mmio_suspended = 0; resumes = 0;
	mmc.ios.power_mode = MMC_POWER_OFF;
	reg_present = SDHCI_CD_STABLE;
	sim_probe(&slot);
	run(1);
	autosuspend_at = jiffies + 50;	/* the first scan's release */
	run(5000);
}

/*
 * A card goes in while suspended (its wakeup is the only report of it), is
 * used, and comes out (an interrupt, in D0: card_event at once, then the
 * removal's rescan 200 ms later powers the slot off).
 */
static void card_cycle(long storm_ms)
{
	reg_present = SDHCI_CARD_PRESENT | SDHCI_CD_STABLE;
	reg_status = SDHCI_INT_CARD_INSERT;
	if (suspended)
		do_resume(0);
	run(300);	/* its rescan finds the card */
	mmc.ios.power_mode = MMC_POWER_ON;
	run(3000);
	reg_present = SDHCI_CD_STABLE;	/* removed */
	storm_until = jiffies + storm_ms;
	sdhci_gl9767_card_event(&host);
	run(200);
	mmc.ios.power_mode = MMC_POWER_OFF;
	autosuspend_at = jiffies + 50;	/* release */
}

int main(void)
{
	long t, first = -1;
	int i;

	boot();
	printf("empty_boot_suspended %d\n", suspended);

	/* As on the G16: wakes straight back for 1 s after the removal. */
	card_cycle(1000);
	t = jiffies;
	run(10000);
	printf("removal_1s_suspended %d\n", suspended);
	printf("removal_1s_settled_ms %ld\n", suspended ? last_suspend - t : -1);

	/* A longer burst than the removal hold: the back-off still settles it. */
	boot();
	card_cycle(3000);
	t = jiffies;
	run(15000);
	printf("removal_3s_suspended %d\n", suspended);
	printf("removal_3s_settled_ms %ld\n", suspended ? last_suspend - t : -1);

	/* Card cycles one after another: the settle time must not grow. */
	boot();
	for (i = 0; i < 6; i++) {
		card_cycle(3000);
		t = jiffies;
		run(70000);
		if (!suspended)
			break;
		if (i == 0)
			first = last_suspend - t;
	}
	printf("cycles_first_settled_ms %ld\n", first);
	printf("cycles_last_settled_ms %ld\n", suspended ? last_suspend - t : -1);

	/* A reader that never settles, latching an insert with no card each time. */
	boot();
	storm_status = SDHCI_INT_CARD_INSERT;
	storm_until = jiffies + 100000000;
	reg_status = storm_status;
	resumes = 0;
	do_resume(0);
	autosuspend_at = jiffies;
	run(600000);
	printf("storm_resumes_600s %d\n", resumes);
	printf("mmio_while_suspended %d\n", mmio_suspended);
	return 0;
}
