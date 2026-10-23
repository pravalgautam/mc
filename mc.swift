// mc — tiny MonitorControl clone for Apple Silicon. DDC/CI over IOAVService.
// Build + install to /Applications: ./build.sh
import AppKit
import IOKit
import IOKit.pwr_mgt
import ServiceManagement
import CoreAudio
import CoreBluetooth
import CoreMediaIO

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ a: CFAllocator?, _ s: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ s: CFTypeRef, _ chip: UInt32, _ off: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ s: CFTypeRef, _ chip: UInt32, _ off: UInt32, _ buf: UnsafeRawPointer, _ len: UInt32) -> IOReturn

// ponytail: first external display only; add an index arg when a second monitor shows up.
func externalService() -> CFTypeRef? {
    var it = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(it) }
    while case let e = IOIteratorNext(it), e != 0 {
        defer { IOObjectRelease(e) }
        let loc = IORegistryEntryCreateCFProperty(e, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if loc == "External", let s = IOAVServiceCreateWithService(kCFAllocatorDefault, e) { return s.takeRetainedValue() }
    }
    return nil
}

func send(_ s: CFTypeRef, _ payload: [UInt8]) -> Bool {
    var p = payload
    p.append(p.reduce(0x6E ^ 0x51, ^))  // DDC checksum
    // ponytail: 2 tries, DDC drops packets now and then
    for _ in 0..<2 {
        usleep(10_000)
        if IOAVServiceWriteI2C(s, 0x37, 0x51, p, UInt32(p.count)) == kIOReturnSuccess { return true }
    }
    return false
}

func setVCP(_ s: CFTypeRef, _ code: UInt8, _ v: UInt16) -> Bool {
    send(s, [0x84, 0x03, code, UInt8(v >> 8), UInt8(v & 0xFF)])
}

func getVCP(_ s: CFTypeRef, _ code: UInt8) -> (cur: Int, max: Int)? {
    guard send(s, [0x82, 0x01, code]) else { return nil }
    usleep(50_000)
    var b = [UInt8](repeating: 0, count: 12)
    guard IOAVServiceReadI2C(s, 0x37, 0x51, &b, 12) == kIOReturnSuccess, b[3] == 0, b[4] == code else { return nil }
    return (Int(b[8]) << 8 | Int(b[9]), Int(b[6]) << 8 | Int(b[7]))
}

func num(_ s: String) -> Int? { s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }

let usage = """
usage: mc brightness [0-100]      get/set brightness (VCP 0x10)
       mc contrast [0-100]        get/set contrast (VCP 0x12)
       mc off | on                monitor power (VCP 0xD6: 1=on 4=off)
       mc get <vcp>               read any VCP code (hex ok: 0xD6)
       mc set <vcp> <value>       write any VCP code
       mc scan                    dump every readable VCP code
       mc [menubar]               menu bar app (default with no args)
"""

let a = Array(CommandLine.arguments.dropFirst())
let cmd = a.first ?? "menubar"  // no args (e.g. launched as mc.app) opens the menu bar

// Gamma state, main thread only. softBrightness is used only when DDC fails.
var softBrightness = 100
var warm = false
var meeting = false  // camera on: full brightness + light warm tint

// Software dimming + warm tint via gamma on external displays. Resets when the app quits.
func applyGamma() {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8), n: UInt32 = 0
    CGGetOnlineDisplayList(8, &ids, &n)
    let k = meeting ? 1 : Float(max(softBrightness, 5)) / 100  // ponytail: 5% floor so the screen never goes fully black
    // ponytail: fixed ~3400K tint, add a strength slider if wanted
    let (r, g, b): (Float, Float, Float) = meeting ? (1, 0.93, 0.85) : warm ? (1, 0.82, 0.62) : (1, 1, 1)
    for id in ids.prefix(Int(n)) where CGDisplayIsBuiltin(id) == 0 {
        CGSetDisplayTransferByFormula(id, 0, k * r, 1, 0, k * g, 1, 0, k * b, 1)
    }
}

// True when any app is using any camera. Needs no camera permission.
func cameraInUse() -> Bool {
    var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                         mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                         mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    var size: UInt32 = 0, used: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0 else { return false }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return false }
    addr.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
    return ids.contains { id in
        var on: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &addr, 0, nil, 4, &used, &on) == 0 && on != 0
    }
}

// Watches one Bluetooth device's signal. Away = no strong signal for `walkDelay` seconds.
// Calibrate if it triggers at your desk: defaults write com.dliver.mc walkRSSI -int -85 (lower = farther)
//                                         defaults write com.dliver.mc walkDelay -int 30
final class WalkAway: NSObject, CBCentralManagerDelegate {
    let prefs = UserDefaults.standard
    var central: CBCentralManager!
    var seen: [UUID: (name: String, rssi: Int)] = [:]
    var lastNear = Date()
    var away = false
    let onChange: (Bool) -> Void
    var target: UUID? {
        get { prefs.string(forKey: "walkDevice").flatMap(UUID.init) }
        set { prefs.set(newValue?.uuidString, forKey: "walkDevice"); lastNear = Date() }
    }

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        prefs.register(defaults: ["walkRSSI": -75, "walkDelay": 20])
        central = CBCentralManager(delegate: self, queue: .main)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let r = rssi.intValue
        guard r < 0 else { return }  // 127 = no reading
        if let name = p.name ?? ad[CBAdvertisementDataLocalNameKey] as? String { seen[p.identifier] = (name, r) }
        if p.identifier == target, r > prefs.integer(forKey: "walkRSSI") { lastNear = Date() }
    }

    func check() {
        guard target != nil else { return }
        let isAway = Date().timeIntervalSince(lastNear) > Double(prefs.integer(forKey: "walkDelay"))
        if isAway != away { away = isAway; onChange(isAway) }
    }
}

final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let svc = externalService()
    let q = DispatchQueue(label: "ddc")
    let prefs = UserDefaults.standard
    var work: [UInt8: DispatchWorkItem] = [:]
    var sliders: [UInt8: NSSlider] = [:]
    var tap: CFMachPort?
    var muted = false
    // Acer has no standard VCP for the power LED. Find it with `mc scan`, then:
    //   defaults write com.dliver.mc ledVCP -int <decimal code>
    // Created on demand so the Bluetooth permission prompt only shows once walk-away is used.
    lazy var walk = WalkAway { [weak self] away in self?.walkAway(away) }
    lazy var ledVCP = UInt8(clamping: prefs.integer(forKey: "ledVCP"))

    override init() {
        super.init()
        prefs.register(defaults: ["meetingGlow": true, "warmAtNight": true, "keys": true, "ledOn": true])
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightness")

        let m = NSMenu()
        addSlider(m, "Brightness", 0x10)
        addSlider(m, "Contrast", 0x12)
        addSlider(m, "Volume", 0x62)
        m.addItem(.separator())

        let inputs = NSMenu()
        for (name, v) in [("DisplayPort", 0x0F), ("HDMI 1", 0x11), ("HDMI 2", 0x12), ("USB-C", 0x1B)] {  // MCCS 0x60 values
            let i = inputs.addItem(withTitle: name, action: #selector(input(_:)), keyEquivalent: "")
            i.target = self
            i.tag = v
        }
        m.addItem(withTitle: "Input", action: nil, keyEquivalent: "").submenu = inputs
        let walkMenu = NSMenu()
        walkMenu.delegate = self
        m.addItem(withTitle: "Walk-Away Off", action: nil, keyEquivalent: "").submenu = walkMenu
        if prefs.string(forKey: "walkDevice") != nil { _ = walk }
        if ledVCP > 0 { toggle(m, "Power Light", #selector(toggleLED(_:)), prefs.bool(forKey: "ledOn")) }
        m.addItem(.separator())

        toggle(m, "Meeting Glow", #selector(toggleGlow(_:)), prefs.bool(forKey: "meetingGlow"))
        toggle(m, "Warm Colour at Night", #selector(toggleWarm(_:)), prefs.bool(forKey: "warmAtNight"))
        toggle(m, "Media Keys Control Monitor", #selector(toggleKeys(_:)), prefs.bool(forKey: "keys"))
        if !prefs.bool(forKey: "loginAsked") {  // turn Start at Login on once, user can untick it
            prefs.set(true, forKey: "loginAsked")
            try? SMAppService.mainApp.register()
        }
        toggle(m, "Start at Login", #selector(toggleLogin(_:)), SMAppService.mainApp.status == .enabled)
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m

        let pairs = Array(sliders)
        q.async { [svc] in
            for (code, s) in pairs {
                let r = svc.flatMap { getVCP($0, code) }
                DispatchQueue.main.async {
                    if let r, r.max > 0 { s.doubleValue = Double(r.cur * 100 / r.max) }
                    else if code != 0x10 { s.isEnabled = false }  // brightness keeps working via gamma
                }
            }
        }

        if prefs.bool(forKey: "keys") { startTap(prompt: true) }
        // Gamma gets reset on sleep/display changes, so reapply.
        Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        NotificationCenter.default.addObserver(self, selector: #selector(tick), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(tick), name: NSWorkspace.didWakeNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkCamera() }
        tick()
    }

    func checkCamera() {
        let on = prefs.bool(forKey: "meetingGlow") && cameraInUse()
        guard on != meeting else { return }
        meeting = on
        if on { if let s = svc { q.async { _ = setVCP(s, 0x10, 100) } } }
        else if let sl = sliders[0x10] { set(0x10, Int(sl.doubleValue)) }  // restore slider brightness
        applyGamma()
    }

    @objc func toggleGlow(_ i: NSMenuItem) {
        i.state = i.state == .on ? .off : .on
        prefs.set(i.state == .on, forKey: "meetingGlow")
        checkCamera()
    }

    func addSlider(_ m: NSMenu, _ title: String, _ code: UInt8) {
        m.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let s = NSSlider(value: 100, minValue: 0, maxValue: 100, target: self, action: #selector(slide(_:)))
        s.tag = Int(code)
        s.frame = NSRect(x: 18, y: 4, width: 180, height: 24)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 216, height: 32))
        box.addSubview(s)
        let i = NSMenuItem()
        i.view = box
        m.addItem(i)
        sliders[code] = s
    }

    @discardableResult
    func toggle(_ m: NSMenu, _ title: String, _ sel: Selector, _ on: Bool) -> NSMenuItem {
        let i = m.addItem(withTitle: title, action: sel, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    func set(_ code: UInt8, _ v: Int) {
        // Drop stale slider values so DDC writes don't pile up.
        work[code]?.cancel()
        let w = DispatchWorkItem { [svc] in
            // ponytail: assumes DDC max is 100 for every code, read max from getVCP if a monitor differs
            let ok = svc.map { setVCP($0, code, UInt16(v)) } ?? false
            guard code == 0x10 else { return }
            DispatchQueue.main.async { softBrightness = ok ? 100 : v; applyGamma() }
        }
        work[code] = w
        q.async(execute: w)
    }

    @objc func slide(_ s: NSSlider) { set(UInt8(s.tag), Int(s.doubleValue)) }

    func step(_ code: UInt8, _ d: Double) {
        guard let s = sliders[code] else { return }
        s.doubleValue = min(100, max(0, s.doubleValue + d))
        set(code, Int(s.doubleValue))
    }

    func toggleMute() {
        muted.toggle()
        let v: UInt16 = muted ? 1 : 2  // VCP 0x8D: 1 = mute, 2 = unmute
        if let s = svc { q.async { _ = setVCP(s, 0x8D, v) } }
    }

    // Volume keys go to the monitor only when it answered DDC and sound is playing through it.
    func monitorAudio() -> Bool {
        guard sliders[0x62]?.isEnabled == true else { return false }
        var dev = AudioDeviceID(), t: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        addr.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeHDMI || t == kAudioDeviceTransportTypeDisplayPort
    }

    @objc func input(_ i: NSMenuItem) {
        let v = UInt16(i.tag)
        if let s = svc { q.async { _ = setVCP(s, 0x60, v) } }
    }

    // Rebuilt each time the Walk-Away submenu opens, strongest signal first.
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let off = m.addItem(withTitle: "Off", action: #selector(pickWalk(_:)), keyEquivalent: "")
        off.target = self
        off.state = walk.target == nil ? .on : .off
        m.addItem(.separator())
        let list = walk.seen.sorted { $0.value.rssi > $1.value.rssi }.prefix(15)
        if list.isEmpty { m.addItem(withTitle: "Scanning… reopen in a few seconds", action: nil, keyEquivalent: "") }
        for (id, d) in list {
            let i = m.addItem(withTitle: "\(d.name)  (\(d.rssi) dBm)", action: #selector(pickWalk(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = id
            i.state = id == walk.target ? .on : .off
        }
    }

    @objc func pickWalk(_ i: NSMenuItem) {
        walk.target = i.representedObject as? UUID
        if walk.away { walk.away = false; walkAway(false) }
    }

    // Monitor off via DDC; if DDC fails, sleep the displays instead (also locks if a password is required).
    func walkAway(_ away: Bool) {
        let fallback = {
            DispatchQueue.main.async {
                if away {
                    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"])
                } else {
                    var id = IOPMAssertionID()
                    IOPMAssertionDeclareUserActivity("mc walk-away" as CFString, kIOPMUserActiveLocal, &id)
                }
            }
        }
        guard let s = svc else { return fallback() }
        q.async { if !setVCP(s, 0xD6, away ? 4 : 1) { fallback() } }
    }

    @objc func toggleLED(_ i: NSMenuItem) {
        let on = i.state != .on
        i.state = on ? .on : .off
        prefs.set(on, forKey: "ledOn")
        // ponytail: assumes 1 = on, 0 = off; check the values `mc get` shows for the LED code
        if let s = svc { q.async { [ledVCP] in _ = setVCP(s, ledVCP, on ? 1 : 0) } }
    }

    @objc func toggleWarm(_ i: NSMenuItem) {
        i.state = i.state == .on ? .off : .on
        prefs.set(i.state == .on, forKey: "warmAtNight")
        tick()
    }

    @objc func toggleKeys(_ i: NSMenuItem) {
        i.state = i.state == .on ? .off : .on
        prefs.set(i.state == .on, forKey: "keys")
        if i.state == .on { startTap(prompt: true) }
        else if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil }
    }

    @objc func toggleLogin(_ i: NSMenuItem) {
        let svc = SMAppService.mainApp
        do { if svc.status == .enabled { try svc.unregister() } else { try svc.register() } }
        catch { SMAppService.openSystemSettingsLoginItems() }
        i.state = svc.status == .enabled ? .on : .off
    }

    @objc func tick() {
        let h = Calendar.current.component(.hour, from: Date())
        warm = prefs.bool(forKey: "warmAtNight") && (h >= 19 || h < 7)  // ponytail: fixed 7pm-7am, use sunset times if it matters
        applyGamma()
        // Picks up the Accessibility grant without a relaunch.
        if prefs.bool(forKey: "keys"), tap == nil { startTap(prompt: false) }
    }

    // Media keys arrive as NX_SYSDEFINED events. Needs Accessibility permission.
    func startTap(prompt: Bool) {
        guard tap == nil, AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary) else { return }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(1 << 14), callback: { _, type, ev, ctx in
            let me = Unmanaged<MenuBar>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout, let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: ev), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(ev) }
            let key = (ns.data1 & 0xFFFF0000) >> 16, down = (ns.data1 & 0xFF00) >> 8 == 0x0A
            // Hold Option to leave keys to macOS (built-in screen, Mac volume).
            guard !ns.modifierFlags.contains(.option) else { return Unmanaged.passUnretained(ev) }
            switch key {
            case 2, 3:  // NX_KEYTYPE_BRIGHTNESS_UP/DOWN
                if down { me.step(0x10, key == 2 ? 6.25 : -6.25) }
            case 0, 1, 7:  // NX_KEYTYPE_SOUND_UP/DOWN, NX_KEYTYPE_MUTE
                guard me.monitorAudio() else { return Unmanaged.passUnretained(ev) }
                if down { key == 7 ? me.toggleMute() : me.step(0x62, key == 0 ? 6.25 : -6.25) }
            default:
                return Unmanaged.passUnretained(ev)
            }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

if cmd == "menubar" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(MenuBar()) { app.run() }
    exit(0)
}
guard let svc = externalService() else { print("no external display found"); exit(1) }

func getOrSet(_ code: UInt8) {
    if a.count > 1, let v = num(a[1]) {
        exit(setVCP(svc, code, UInt16(clamping: v)) ? 0 : 1)
    }
    guard let r = getVCP(svc, code) else { print("read failed"); exit(1) }
    print("\(r.cur)/\(r.max)")
}

switch cmd {
case "brightness": getOrSet(0x10)
case "contrast": getOrSet(0x12)
case "on": exit(setVCP(svc, 0xD6, 1) ? 0 : 1)
case "off": exit(setVCP(svc, 0xD6, 4) ? 0 : 1)
case "get" where a.count == 2:
    guard let c = num(a[1]), let r = getVCP(svc, UInt8(c)) else { print("read failed"); exit(1) }
    print("\(r.cur)/\(r.max)")
case "set" where a.count == 3:
    guard let c = num(a[1]), let v = num(a[2]) else { print(usage); exit(1) }
    exit(setVCP(svc, UInt8(c), UInt16(clamping: v)) ? 0 : 1)
case "scan":
    for c in 0...255 { if let r = getVCP(svc, UInt8(c)) { print(String(format: "0x%02X  %d/%d", c, r.cur, r.max)) } }
default: print(usage); exit(1)
}
