// SPDX-License-Identifier: GPL-2.0-or-later
// Excerpt of drivers/platform/x86/asus-wmi.c, Linux v7.2.8 with linux-omarchy's
// 0800 and 0803 applied: lines 5313-5442, the hibernate/resume callbacks.
// tests/ci/linux-omarchy-local-patches.sh applies 0808 to it (and, online,
// checks it still matches the real file).

/* Platform driver - hibernate/resume callbacks *******************************/

static int asus_hotk_thaw(struct device *device)
{
	struct asus_wmi *asus = dev_get_drvdata(device);

	if (asus->wlan.rfkill) {
		bool wlan;

		/*
		 * Work around bios bug - acpi _PTS turns off the wireless led
		 * during suspend.  Normally it restores it on resume, but
		 * we should kick it ourselves in case hibernation is aborted.
		 */
		wlan = asus_wmi_get_devstate_simple(asus, ASUS_WMI_DEVID_WLAN);
		asus_wmi_set_devstate(ASUS_WMI_DEVID_WLAN, wlan, NULL);
	}

	return 0;
}

static int asus_hotk_resume(struct device *device)
{
	struct asus_wmi *asus = dev_get_drvdata(device);

	if (!IS_ERR_OR_NULL(asus->kbd_led.dev))
		kbd_led_update(asus);

	if (asus_wmi_has_fnlock_key(asus))
		asus_wmi_fnlock_update(asus);

	asus_wmi_tablet_mode_get_state(asus);

	return 0;
}

static int asus_hotk_restore(struct device *device)
{
	struct asus_wmi *asus = dev_get_drvdata(device);
	int bl;

	/* Refresh both wlan rfkill state and pci hotplug */
	if (asus->wlan.rfkill)
		asus_rfkill_hotplug(asus);

	if (asus->bluetooth.rfkill) {
		bl = !asus_wmi_get_devstate_simple(asus,
						   ASUS_WMI_DEVID_BLUETOOTH);
		rfkill_set_sw_state(asus->bluetooth.rfkill, bl);
	}
	if (asus->wimax.rfkill) {
		bl = !asus_wmi_get_devstate_simple(asus, ASUS_WMI_DEVID_WIMAX);
		rfkill_set_sw_state(asus->wimax.rfkill, bl);
	}
	if (asus->wwan3g.rfkill) {
		bl = !asus_wmi_get_devstate_simple(asus, ASUS_WMI_DEVID_WWAN3G);
		rfkill_set_sw_state(asus->wwan3g.rfkill, bl);
	}
	if (asus->gps.rfkill) {
		bl = !asus_wmi_get_devstate_simple(asus, ASUS_WMI_DEVID_GPS);
		rfkill_set_sw_state(asus->gps.rfkill, bl);
	}
	if (asus->uwb.rfkill) {
		bl = !asus_wmi_get_devstate_simple(asus, ASUS_WMI_DEVID_UWB);
		rfkill_set_sw_state(asus->uwb.rfkill, bl);
	}
	if (!IS_ERR_OR_NULL(asus->kbd_led.dev))
		kbd_led_update(asus);
	if (asus->oobe_state_available) {
		/*
		 * Disable OOBE state, so that e.g. the keyboard backlight
		 * works.
		 */
		asus_wmi_set_devstate(ASUS_WMI_DEVID_OOBE, 1, NULL);
	}

	if (asus_wmi_has_fnlock_key(asus))
		asus_wmi_fnlock_update(asus);

	asus_wmi_tablet_mode_get_state(asus);
	return 0;
}

static int asus_hotk_prepare(struct device *device)
{
	if (use_ally_mcu_hack == ASUS_WMI_ALLY_MCU_HACK_ENABLED) {
		acpi_execute_simple_method(NULL, ASUS_USB0_PWR_EC0_CSEE,
					   ASUS_USB0_PWR_EC0_CSEE_OFF);
		msleep(ASUS_USB0_PWR_EC0_CSEE_WAIT);
	}
	return 0;
}

#if defined(CONFIG_SUSPEND)
static void asus_ally_s2idle_restore(void)
{
	if (use_ally_mcu_hack == ASUS_WMI_ALLY_MCU_HACK_ENABLED) {
		acpi_execute_simple_method(NULL, ASUS_USB0_PWR_EC0_CSEE,
					   ASUS_USB0_PWR_EC0_CSEE_ON);
		msleep(ASUS_USB0_PWR_EC0_CSEE_WAIT);
	}
}

/* Use only for Ally devices due to the wake_on_ac */
static struct acpi_s2idle_dev_ops asus_ally_s2idle_dev_ops = {
	.restore = asus_ally_s2idle_restore,
};

static void asus_s2idle_check_register(void)
{
	if (acpi_register_lps0_dev(&asus_ally_s2idle_dev_ops))
		pr_warn("failed to register LPS0 sleep handler in asus-wmi\n");
}

static void asus_s2idle_check_unregister(void)
{
	acpi_unregister_lps0_dev(&asus_ally_s2idle_dev_ops);
}
#else
static void asus_s2idle_check_register(void) {}
static void asus_s2idle_check_unregister(void) {}
#endif /* CONFIG_SUSPEND */

static const struct dev_pm_ops asus_pm_ops = {
	.thaw = asus_hotk_thaw,
	.restore = asus_hotk_restore,
	.resume = asus_hotk_resume,
	.prepare = asus_hotk_prepare,
};
