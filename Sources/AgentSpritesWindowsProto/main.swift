// AgentSprites Windows Prototype
//
// Minimal proof-of-concept demonstrating:
// 1. A transparent, always-on-top Win32 overlay window from Swift
// 2. Basic sprite rendering using GDI+
// 3. Socket-based IPC with the AgentSprites CLI
//
// Build: swift build (on Windows with Swift toolchain)
// Run:   .build\debug\AgentSpritesWindowsProto.exe

#if os(Windows)
import WinSDK
import Foundation
import AgentSpritesCore

// MARK: - Win32 Constants

let WS_EX_LAYERED: DWORD = 0x00080000
let WS_EX_TRANSPARENT: DWORD = 0x00000020
let WS_EX_TOPMOST: DWORD = 0x00000008
let WS_EX_TOOLWINDOW: DWORD = 0x00000080
let WS_POPUP: DWORD = 0x80000000
let WS_VISIBLE: DWORD = 0x10000000
let LWA_ALPHA: DWORD = 0x00000002
let LWA_COLORKEY: DWORD = 0x00000001

let WINDOW_WIDTH: Int32 = 64
let WINDOW_HEIGHT: Int32 = 64

// MARK: - Window Class Registration

let windowClassName = "AgentSpritesOverlay"

func registerWindowClass(_ hInstance: HINSTANCE) -> Bool {
    var wc = WNDCLASSEXW()
    wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
    wc.lpfnWndProc = windowProc
    wc.hInstance = hInstance
    wc.hCursor = LoadCursorW(nil, IDC_ARROW)
    // Use a magenta background as the transparency color key
    wc.hbrBackground = CreateSolidBrush(RGB(255, 0, 255))

    windowClassName.withCString(encodedAs: UTF16.self) { className in
        wc.lpszClassName = className
    }

    return RegisterClassExW(&wc) != 0
}

// MARK: - Window Procedure

func windowProc(
    hwnd: HWND?,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM
) -> LRESULT {
    switch Int32(message) {
    case WM_PAINT:
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else {
            return 0
        }

        // Draw a simple sprite placeholder (green circle on magenta background)
        // Magenta (RGB 255,0,255) is our transparency color key
        let brush = CreateSolidBrush(RGB(0, 200, 0))
        let oldBrush = SelectObject(hdc, brush)
        Ellipse(hdc, 4, 4, WINDOW_WIDTH - 4, WINDOW_HEIGHT - 4)
        SelectObject(hdc, oldBrush)
        DeleteObject(brush)

        EndPaint(hwnd, &ps)
        return 0

    case WM_DESTROY:
        PostQuitMessage(0)
        return 0

    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

// MARK: - Create Overlay Window

func createOverlayWindow(_ hInstance: HINSTANCE) -> HWND? {
    let exStyle = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
    let style = WS_POPUP | WS_VISIBLE

    var hwnd: HWND?
    windowClassName.withCString(encodedAs: UTF16.self) { className in
        hwnd = CreateWindowExW(
            exStyle,
            className,
            nil,                // No title
            style,
            100, 100,           // Position
            WINDOW_WIDTH, WINDOW_HEIGHT,
            nil,                // No parent
            nil,                // No menu
            hInstance,
            nil                 // No extra data
        )
    }

    guard let hwnd else { return nil }

    // Set magenta as the transparent color key
    // Any pixel that is RGB(255, 0, 255) will be fully transparent
    SetLayeredWindowAttributes(hwnd, COLORREF(RGB(255, 0, 255)), 255, LWA_COLORKEY)

    return hwnd
}

// MARK: - Main

func RGB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> COLORREF {
    COLORREF(UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16))
}

print("AgentSprites Windows Prototype")
print("Creating transparent overlay window...")

let hInstance = GetModuleHandleW(nil)!

guard registerWindowClass(hInstance) else {
    print("ERROR: Failed to register window class")
    exit(1)
}

guard let hwnd = createOverlayWindow(hInstance) else {
    print("ERROR: Failed to create overlay window")
    exit(1)
}

print("Window created successfully!")
print("You should see a green circle floating on screen.")
print("Press Ctrl+C to exit.")

// Start socket IPC listener in background
let ipc = SocketIPCProvider()
ipc.observeEvents(
    onSessionEvent: { event in
        print("Received session event: \(event.eventName) for \(event.sessionId)")
    },
    onSessionEnd: { sessionId in
        print("Session ended: \(sessionId)")
    }
)

// Win32 message loop
var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}

ipc.stopObserving()

#else

// Stub for non-Windows platforms
import Foundation
print("AgentSpritesWindowsProto is a Windows-only prototype.")
print("Build and run this on Windows with the Swift toolchain installed.")
print("")
print("Prerequisites:")
print("  1. Install Swift from https://swift.org/install/windows/")
print("  2. Install Visual Studio 2022 with C++ workload")
print("  3. Run: swift build --target AgentSpritesWindowsProto")
print("  4. Run: .build\\debug\\AgentSpritesWindowsProto.exe")

#endif
