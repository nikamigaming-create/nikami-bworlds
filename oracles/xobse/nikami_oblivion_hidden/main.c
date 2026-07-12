#include <Windows.h>
#include <winnt.h>
#include <string.h>

typedef HWND (WINAPI *CreateWindowExAFn)(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
typedef HWND (WINAPI *CreateWindowExWFn)(DWORD, LPCWSTR, LPCWSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID);
typedef BOOL (WINAPI *ShowWindowFn)(HWND, int);
typedef BOOL (WINAPI *ShowWindowAsyncFn)(HWND, int);
typedef BOOL (WINAPI *SetWindowPosFn)(HWND, HWND, int, int, int, int, UINT);
typedef HWND (WINAPI *GetActiveWindowFn)(void);
typedef LONG (WINAPI *GetWindowLongAFn)(HWND, int);

static CreateWindowExAFn sCreateWindowExA;
static CreateWindowExWFn sCreateWindowExW;
static ShowWindowFn sShowWindow;
static ShowWindowAsyncFn sShowWindowAsync;
static SetWindowPosFn sSetWindowPos;
static GetActiveWindowFn sGetActiveWindow;
static GetWindowLongAFn sGetWindowLongA;
static HWND sGameWindow;

static HWND WINAPI hiddenCreateWindowExA(DWORD exStyle, LPCSTR className, LPCSTR windowName, DWORD style,
    int x, int y, int width, int height, HWND parent, HMENU menu, HINSTANCE instance, LPVOID parameter)
{
    HWND created = sCreateWindowExA(exStyle & ~WS_EX_TOPMOST, className, windowName, style & ~WS_VISIBLE,
        x, y, width, height, parent, menu, instance, parameter);
    if (parent == NULL && sGameWindow == NULL)
        sGameWindow = created;
    return created;
}

static HWND WINAPI hiddenCreateWindowExW(DWORD exStyle, LPCWSTR className, LPCWSTR windowName, DWORD style,
    int x, int y, int width, int height, HWND parent, HMENU menu, HINSTANCE instance, LPVOID parameter)
{
    HWND created = sCreateWindowExW(exStyle & ~WS_EX_TOPMOST, className, windowName, style & ~WS_VISIBLE,
        x, y, width, height, parent, menu, instance, parameter);
    if (parent == NULL && sGameWindow == NULL)
        sGameWindow = created;
    return created;
}

static BOOL WINAPI hiddenShowWindow(HWND window, int command)
{
    return sShowWindow(window, SW_HIDE);
}

static BOOL WINAPI hiddenShowWindowAsync(HWND window, int command)
{
    return sShowWindowAsync(window, SW_HIDE);
}

static BOOL WINAPI hiddenSetWindowPos(HWND window, HWND insertAfter, int x, int y, int width, int height, UINT flags)
{
    return sSetWindowPos(window, insertAfter, x, y, width, height,
        (flags & ~SWP_SHOWWINDOW) | SWP_HIDEWINDOW | SWP_NOACTIVATE);
}

static BOOL WINAPI suppressWindowAction(HWND window)
{
    return TRUE;
}

static HWND WINAPI suppressFocus(HWND window)
{
    return NULL;
}

static BOOL WINAPI suppressClipCursor(const RECT* rectangle)
{
    return TRUE;
}

static BOOL WINAPI suppressSetCursorPos(int x, int y)
{
    return TRUE;
}

static HWND WINAPI virtualActiveWindow(void)
{
    return sGameWindow != NULL ? sGameWindow : sGetActiveWindow();
}

static LONG WINAPI virtualWindowLongA(HWND window, int index)
{
    LONG value = sGetWindowLongA(window, index);
    if (window == sGameWindow && index == GWL_STYLE)
        value |= WS_VISIBLE;
    return value;
}

static BOOL patchImport(const char* importName, FARPROC replacement, FARPROC* original)
{
    BYTE* module = (BYTE*)GetModuleHandleA(NULL);
    IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)module;
    IMAGE_NT_HEADERS32* nt;
    IMAGE_DATA_DIRECTORY directory;
    IMAGE_IMPORT_DESCRIPTOR* descriptor;
    HMODULE user32;
    FARPROC exported;
    if (module == NULL || dos->e_magic != IMAGE_DOS_SIGNATURE)
        return FALSE;
    nt = (IMAGE_NT_HEADERS32*)(module + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE)
        return FALSE;
    directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (directory.VirtualAddress == 0)
        return FALSE;
    user32 = GetModuleHandleA("user32.dll");
    exported = user32 != NULL ? GetProcAddress(user32, importName) : NULL;
    descriptor = (IMAGE_IMPORT_DESCRIPTOR*)(module + directory.VirtualAddress);
    for (; descriptor->Name != 0; ++descriptor)
    {
        const char* libraryName = (const char*)(module + descriptor->Name);
        IMAGE_THUNK_DATA32* names;
        IMAGE_THUNK_DATA32* addresses;
        if (_stricmp(libraryName, "user32.dll") != 0)
            continue;
        names = descriptor->OriginalFirstThunk != 0
            ? (IMAGE_THUNK_DATA32*)(module + descriptor->OriginalFirstThunk) : NULL;
        addresses = (IMAGE_THUNK_DATA32*)(module + descriptor->FirstThunk);
        for (DWORD index = 0; addresses[index].u1.Function != 0; ++index)
        {
            BOOL match = FALSE;
            if (names != NULL && !(names[index].u1.Ordinal & IMAGE_ORDINAL_FLAG32))
            {
                IMAGE_IMPORT_BY_NAME* entry = (IMAGE_IMPORT_BY_NAME*)(module + names[index].u1.AddressOfData);
                match = strcmp((const char*)entry->Name, importName) == 0;
            }
            else if (exported != NULL)
                match = (FARPROC)addresses[index].u1.Function == exported;
            if (match)
            {
                DWORD oldProtection = 0;
                DWORD ignored = 0;
                if (!VirtualProtect(&addresses[index].u1.Function, sizeof(DWORD), PAGE_READWRITE, &oldProtection))
                    return FALSE;
                if (original != NULL)
                    *original = (FARPROC)addresses[index].u1.Function;
                addresses[index].u1.Function = (DWORD)replacement;
                VirtualProtect(&addresses[index].u1.Function, sizeof(DWORD), oldProtection, &ignored);
                FlushInstructionCache(GetCurrentProcess(), &addresses[index].u1.Function, sizeof(DWORD));
                return TRUE;
            }
        }
    }
    return FALSE;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(instance);
        patchImport("CreateWindowExA", (FARPROC)hiddenCreateWindowExA, (FARPROC*)&sCreateWindowExA);
        patchImport("CreateWindowExW", (FARPROC)hiddenCreateWindowExW, (FARPROC*)&sCreateWindowExW);
        patchImport("ShowWindow", (FARPROC)hiddenShowWindow, (FARPROC*)&sShowWindow);
        patchImport("ShowWindowAsync", (FARPROC)hiddenShowWindowAsync, (FARPROC*)&sShowWindowAsync);
        patchImport("SetWindowPos", (FARPROC)hiddenSetWindowPos, (FARPROC*)&sSetWindowPos);
        patchImport("GetActiveWindow", (FARPROC)virtualActiveWindow, (FARPROC*)&sGetActiveWindow);
        patchImport("GetWindowLongA", (FARPROC)virtualWindowLongA, (FARPROC*)&sGetWindowLongA);
        patchImport("SetForegroundWindow", (FARPROC)suppressWindowAction, NULL);
        patchImport("BringWindowToTop", (FARPROC)suppressWindowAction, NULL);
        patchImport("SetActiveWindow", (FARPROC)suppressFocus, NULL);
        patchImport("SetFocus", (FARPROC)suppressFocus, NULL);
        patchImport("SetCapture", (FARPROC)suppressFocus, NULL);
        patchImport("ClipCursor", (FARPROC)suppressClipCursor, NULL);
        patchImport("SetCursorPos", (FARPROC)suppressSetCursorPos, NULL);
    }
    return TRUE;
}
