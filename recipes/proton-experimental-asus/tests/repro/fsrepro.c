/* fsrepro: emulated exclusive fullscreen on one display while the compositor
 * may place the window on another. Logs what Win32 believes vs. the pointer.
 *
 * usage: fsrepro.exe [display_index] [width] [height] [seconds] [flags]
 *   display_index  0-based Win32 display to change the mode of and cover
 *                  (default 0, i.e. \\.\DISPLAY1, like a game's "monitor 0")
 *   width height   mode to set (default 2560 1440)
 *   seconds        how long to run (default 20)
 *   flags          b: start borderless on the monitor the window manager puts the window on,
 *                     switch to exclusive after 3 s (what a game's display-mode menu does)
 *                  c: ClipCursor() to the window while exclusive, again whenever it moves, as games do
 *                  f: put the window back on the chosen display when it is moved off it
 * The log goes to stdout, or to the file in FSREPRO_LOG (e.g. Z:/tmp/fsrepro.log) when set:
 * under Proton's steam.exe the program's stdout may not reach the terminal.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static FILE *out;
static POINT last_client = {-1, -1};
static int target;
static BOOL exclusive, fight, clip;
static RECT target_rect;

static void logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(out, fmt, ap);
    va_end(ap);
    fflush(out);
}

static BOOL CALLBACK mon_cb(HMONITOR m, HDC dc, LPRECT r, LPARAM lp)
{
    MONITORINFOEXW mi = {.cbSize = sizeof(mi)};
    GetMonitorInfoW(m, (MONITORINFO *)&mi);
    logf_("  monitor %ls %ld,%ld-%ld,%ld%s\n", mi.szDevice, mi.rcMonitor.left, mi.rcMonitor.top,
          mi.rcMonitor.right, mi.rcMonitor.bottom, (mi.dwFlags & MONITORINFOF_PRIMARY) ? " primary" : "");
    return TRUE;
}

static void dump_state(HWND hwnd, const char *why)
{
    RECT wr, cr;
    POINT cur, cl;
    MONITORINFOEXW mi = {.cbSize = sizeof(mi)};
    GetWindowRect(hwnd, &wr);
    GetClientRect(hwnd, &cr);
    GetCursorPos(&cur);
    cl = cur;
    ScreenToClient(hwnd, &cl);
    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), (MONITORINFO *)&mi);
    logf_("%s: window %ld,%ld-%ld,%ld on %ls; cursor screen %ld,%ld client %ld,%ld; last WM_MOUSEMOVE %ld,%ld\n",
          why, wr.left, wr.top, wr.right, wr.bottom, mi.szDevice, cur.x, cur.y, cl.x, cl.y,
          last_client.x, last_client.y);
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_MOUSEMOVE:
        last_client.x = (short)LOWORD(lp);
        last_client.y = (short)HIWORD(lp);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_LBUTTONDOWN:
        logf_("click: client %d,%d\n", (short)LOWORD(lp), (short)HIWORD(lp));
        dump_state(hwnd, "click");
        return 0;
    case WM_WINDOWPOSCHANGED:
    {
        WINDOWPOS *p = (WINDOWPOS *)lp;
        static int fights;
        logf_("WM_WINDOWPOSCHANGED %d,%d %dx%d flags %#x\n", p->x, p->y, p->cx, p->cy, p->flags);
        if (exclusive && clip)
        {
            RECT r;
            GetWindowRect(hwnd, &r);
            logf_("ClipCursor %ld,%ld-%ld,%ld = %d\n", r.left, r.top, r.right, r.bottom, ClipCursor(&r));
        }
        if (exclusive && fight && !(p->flags & SWP_NOMOVE) && (p->x != target_rect.left || p->y != target_rect.top)
            && fights++ < 5)
        {
            logf_("moved off the chosen display, moving back (%d)\n", fights);
            SetWindowPos(hwnd, HWND_TOPMOST, target_rect.left, target_rect.top, target_rect.right - target_rect.left,
                         target_rect.bottom - target_rect.top, SWP_NOACTIVATE);
        }
        break;
    }
    case WM_TIMER:
        dump_state(hwnd, "tick");
        return 0;
    case WM_PAINT:
    {
        PAINTSTRUCT ps;
        RECT cr;
        HDC dc = BeginPaint(hwnd, &ps);
        GetClientRect(hwnd, &cr);
        FillRect(dc, &cr, GetStockObject(BLACK_BRUSH));
        HPEN grid = CreatePen(PS_SOLID, 1, RGB(60, 60, 60)), red = CreatePen(PS_SOLID, 3, RGB(255, 0, 0));
        HGDIOBJ old = SelectObject(dc, grid);
        for (int x = 0; x < cr.right; x += 160) { MoveToEx(dc, x, 0, NULL); LineTo(dc, x, cr.bottom); }
        for (int y = 0; y < cr.bottom; y += 160) { MoveToEx(dc, 0, y, NULL); LineTo(dc, cr.right, y); }
        SelectObject(dc, red);
        MoveToEx(dc, last_client.x - 40, last_client.y, NULL); LineTo(dc, last_client.x + 40, last_client.y);
        MoveToEx(dc, last_client.x, last_client.y - 40, NULL); LineTo(dc, last_client.x, last_client.y + 40);
        SelectObject(dc, old);
        DeleteObject(grid);
        DeleteObject(red);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void get_display_rect(const WCHAR *dev, RECT *rect)
{
    DEVMODEW dm = {.dmSize = sizeof(dm)};
    MONITORINFO mi = {.cbSize = sizeof(mi)};
    POINT pt;
    EnumDisplaySettingsW(dev, ENUM_CURRENT_SETTINGS, &dm);
    pt.x = dm.dmPosition.x;
    pt.y = dm.dmPosition.y;
    GetMonitorInfoW(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST), &mi);
    *rect = mi.rcMonitor;
}

static void pump(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    MSG msg;
    while (GetTickCount() < end)
    {
        if (MsgWaitForMultipleObjects(0, NULL, FALSE, 100, QS_ALLINPUT) == WAIT_OBJECT_0)
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
            {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
    }
}

int main(int argc, char **argv)
{
    int w = 2560, h = 1440, secs = 20;
    const char *flags = "";
    WCHAR dev[32];
    DEVMODEW dm = {.dmSize = sizeof(dm)};
    RECT start;
    LONG ret;
    HWND hwnd;

    out = stdout;
    if (getenv("FSREPRO_LOG") && !(out = fopen(getenv("FSREPRO_LOG"), "w"))) out = stdout;
    if (argc > 1) target = atoi(argv[1]);
    if (argc > 3) { w = atoi(argv[2]); h = atoi(argv[3]); }
    if (argc > 4) secs = atoi(argv[4]);
    if (argc > 5) flags = argv[5];
    fight = !!strchr(flags, 'f');
    clip = !!strchr(flags, 'c');
    SetProcessDPIAware();
    swprintf(dev, 32, L"\\\\.\\DISPLAY%d", target + 1);

    logf_("monitors:\n");
    EnumDisplayMonitors(NULL, NULL, mon_cb, 0);

    WNDCLASSW wc = {.lpfnWndProc = wndproc, .hInstance = GetModuleHandleW(NULL),
                    .hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW), .lpszClassName = L"fsrepro"};
    RegisterClassW(&wc);

    if (strchr(flags, 'b'))
    {
        /* borderless: cover whichever monitor the window manager shows us on */
        hwnd = CreateWindowExW(0, L"fsrepro", L"fsrepro", WS_POPUP, 0, 0, 640, 480, NULL, NULL, wc.hInstance, NULL);
        ShowWindow(hwnd, SW_SHOW);
        pump(1500);
        MONITORINFO mi = {.cbSize = sizeof(mi)};
        GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi);
        start = mi.rcMonitor;
        SetWindowPos(hwnd, HWND_TOP, start.left, start.top, start.right - start.left, start.bottom - start.top, 0);
        pump(1500);
        dump_state(hwnd, "borderless");
    }
    else hwnd = NULL;

    ret = ChangeDisplaySettingsExW(dev, &(DEVMODEW){.dmSize = sizeof(dm), .dmPelsWidth = w, .dmPelsHeight = h,
                                   .dmFields = DM_PELSWIDTH | DM_PELSHEIGHT}, NULL, CDS_FULLSCREEN, NULL);
    logf_("ChangeDisplaySettingsEx(%ls, %dx%d) = %ld\n", dev, w, h, ret);
    logf_("monitors after mode change:\n");
    EnumDisplayMonitors(NULL, NULL, mon_cb, 0);

    /* cover the chosen display, as a game in exclusive fullscreen does */
    get_display_rect(dev, &target_rect);
    exclusive = TRUE;
    if (!hwnd)
        hwnd = CreateWindowExW(WS_EX_TOPMOST, L"fsrepro", L"fsrepro", WS_POPUP | WS_VISIBLE, target_rect.left,
                               target_rect.top, target_rect.right - target_rect.left,
                               target_rect.bottom - target_rect.top, NULL, NULL, wc.hInstance, NULL);
    else
        SetWindowPos(hwnd, HWND_TOPMOST, target_rect.left, target_rect.top, target_rect.right - target_rect.left,
                     target_rect.bottom - target_rect.top, 0);
    SetForegroundWindow(hwnd);
    if (clip)
    {
        RECT r;
        GetWindowRect(hwnd, &r);
        logf_("ClipCursor %ld,%ld-%ld,%ld = %d\n", r.left, r.top, r.right, r.bottom, ClipCursor(&r));
    }
    dump_state(hwnd, "exclusive");
    SetTimer(hwnd, 1, 1000, NULL);
    pump(secs * 1000);
    dump_state(hwnd, "final");
    ClipCursor(NULL);
    DestroyWindow(hwnd);
    ChangeDisplaySettingsExW(dev, NULL, NULL, 0, NULL);
    return 0;
}
