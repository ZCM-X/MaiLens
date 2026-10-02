import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraController()
    @StateObject private var gimbalLock = GimbalLockController()
    @StateObject private var machineLock = MachineGeometryLockController()
    @StateObject private var recorder = ProcessedVideoRecorder()
    @State private var settings = LensCorrectionSettings.load()
    @AppStorage("maiLens.machineBorderGapMM") private var machineBorderGapMM = 75.0
    @AppStorage("maiLens.rectifyStrength") private var rectifyStrength = 1.0
    @AppStorage("maiLens.ringRoundStrength") private var ringRoundStrength = 1.0
    @State private var sharedProfile: LensProfileFile?

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.048, blue: 0.055).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    cameraPreview
                    cameraControls
                    lockControls
                    machineGeometryControls
                    recordingControls
                    correctionControls
                    calibrationNote
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 32)
            }
        }
        .onChange(of: settings) { _, newValue in newValue.save() }
        .onChange(of: machineBorderGapMM) { _, newValue in
            machineLock.updateMachineBorderGapMM(newValue)
        }
        .onChange(of: rectifyStrength) { _, newValue in
            machineLock.updateRectifyStrength(newValue)
        }
        .onChange(of: ringRoundStrength) { _, newValue in
            machineLock.updateRingRoundStrength(newValue)
        }
        .onAppear {
            machineLock.updateMachineBorderGapMM(machineBorderGapMM)
            machineLock.updateRectifyStrength(rectifyStrength)
            machineLock.updateRingRoundStrength(ringRoundStrength)
        }
        .sheet(item: $sharedProfile) { profile in
            ShareProfileSheet(url: profile.url)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                camera.start()
                gimbalLock.start()
                machineLock.start()
            } else {
                camera.stop()
                gimbalLock.stop()
                machineLock.stop()
                if recorder.isRecording {
                    recorder.stop { camera.stopAudioCapture() }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MAI LENS")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .tracking(2.6)
                    .foregroundStyle(Color.mint)
                Text("模拟云台稳定")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(camera.isRunning ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(camera.isRunning ? "0.5× 实时" : "连接中")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }

    private var cameraPreview: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("实时预览", systemImage: "viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(settings.correctionEnabled ? "RECTIFIED" : "RAW LENS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(settings.correctionEnabled ? Color.mint : Color.orange)
            }

            ZStack {
                FisheyeCameraPreview(camera: camera, gimbalLock: gimbalLock, machineLock: machineLock, recorder: recorder, settings: settings)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)

                if let message = camera.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 25))
                        Text(message)
                            .font(.system(size: 13, weight: .medium))
                            .multilineTextAlignment(.center)
                        Button("重试连接") { camera.start() }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.mint)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 22))
                } else if !camera.isRunning {
                    ProgressView("正在启动 0.5× 摄像头…")
                        .tint(.mint)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(16)
                        .background(.black.opacity(0.58), in: Capsule())
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    settings.correctionEnabled.toggle()
                } label: {
                    Image(systemName: settings.correctionEnabled ? "circle.lefthalf.filled" : "circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel("切换鱼眼矫正")
                .padding(12)
            }
            .overlay(alignment: .topLeading) {
                if recorder.isRecording {
                    Label("REC", systemImage: "record.circle.fill")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.red.opacity(0.88), in: Capsule())
                    .padding(12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if gimbalLock.isGimbalEnabled {
                    Button {
                        gimbalLock.recenterGimbal()
                    } label: {
                        Label("锁定当前画面", systemImage: "gyroscope")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.62), in: Capsule())
                    }
                    .padding(12)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if machineLock.isEnabled {
                    Label(machineLock.previewStatusTitle,
                          systemImage: machineLock.detectorAvailable
                            ? (machineLock.status == .tracking ? "scope" : "viewfinder")
                            : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(machineLock.detectorAvailable && machineLock.status == .tracking
                                         ? Color.mint
                                         : (machineLock.detectorAvailable ? Color.white : Color.orange))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(12)
                }
            }

            Text(camera.cameraName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
    }

    private var lockControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Circle()
                    .fill(gimbalLock.errorMessage == nil
                          ? (gimbalLock.isGimbalEnabled ? Color.green : Color.gray)
                          : Color.orange)
                    .frame(width: 8, height: 8)
                Text(gimbalLock.errorMessage == nil
                     ? (gimbalLock.isGimbalEnabled ? "锁定模式运行中" : "锁定模式已关闭")
                     : "陀螺仪不可用")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("LOCK")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.mint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.mint.opacity(0.12), in: Capsule())
            }

            Text("锁定当前视线，用 120Hz 陀螺仪抵消手机的左右转动、俯仰和横滚；鱼眼画面会预留裁切空间，让同一方向保持在画面中。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    gimbalLock.toggleGimbal()
                } label: {
                    Label(
                        gimbalLock.isGimbalEnabled ? "关闭锁定模式" : "开启锁定模式",
                        systemImage: "gyroscope"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionStyle())

                Button {
                    gimbalLock.recenterGimbal()
                } label: {
                    Label("重新锁定当前画面", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(!gimbalLock.isGimbalEnabled)
            }

            if let errorMessage = gimbalLock.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(17)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
    }

    private var machineGeometryControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Circle()
                    .fill(machineLock.isEnabled
                          ? (machineLock.status == .tracking ? Color.green : Color.orange)
                          : Color.gray)
                    .frame(width: 8, height: 8)
                Text(machineLock.isEnabled ? machineLock.status.title : "机台几何锁定已关闭")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(machineLock.detectorAvailable ? "AI 已加载" : "模型未加载")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(machineLock.detectorAvailable ? Color.mint : Color.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.08), in: Capsule())
            }

            Text("以内屏圆心转动虚拟相机视线并进行鱼眼射线重投影；75 mm 外框—内屏间距用于估算手机距离并补偿前后移动。横向视场保持 103°，画面不做横纵拉伸。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)

            Text(!machineLock.framing.isActive
                 ? "等待检测外框与内屏"
                 : machineLock.framing.screenEllipseDetected
                    ? "内屏圆心已识别 · 虚拟视角已对准"
                    : "使用内屏框中心 · 虚拟视角已对准")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(machineLock.framing.screenEllipseDetected ? Color.mint : Color.orange)

            if let detectorLoadMessage = machineLock.detectorLoadMessage {
                Text(detectorLoadMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    machineLock.toggle()
                } label: {
                    Label(machineLock.isEnabled ? "关闭机台锁定" : "开启机台锁定",
                          systemImage: machineLock.isEnabled ? "scope" : "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionStyle())

                if machineLock.framing.isActive {
                    Text(String(format: "× %.2f", machineLock.framing.zoom))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.mint)
                        .frame(minWidth: 62)
                        .padding(.vertical, 13)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                }
            }

            HStack {
                Text(String(format: "虚拟视场 %.0f°", settings.horizontalFOV))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(String(format: "实体间距 %.0f mm", machineBorderGapMM))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.mint)
            }

            TuningSlider(
                title: "外框到内屏实测间距",
                value: $machineBorderGapMM,
                range: 25...200,
                valueFormat: "%.0f mm"
            )

            TuningSlider(
                title: "拉正内屏成正圆",
                value: $rectifyStrength,
                range: 0...1,
                valueFormat: "%.2f"
            )

            TuningSlider(
                title: "八按键拉回同一圈",
                value: $ringRoundStrength,
                range: 0...1,
                valueFormat: "%.2f"
            )

            if machineLock.isEnabled && machineLock.framing.isActive {
                let gaps = machineLock.framing
                if let distance = gaps.estimatedMachineDistanceMM {
                    Text(String(format: "估计手机到机台距离 %.0f mm", distance))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.mint.opacity(0.85))
                }
                Text(String(format: "重投影后四边间距(px)  左 %.0f  右 %.0f  上 %.0f  下 %.0f",
                            gaps.leftGap, gaps.rightGap, gaps.topGap, gaps.bottomGap))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Text(String(format: "内屏椭圆 %.3f   八按键绕圈离散 %.1f%%",
                            Double(machineLock.screenFlatness),
                            Double(machineLock.ringSpread) * 100))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(17)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "camera.aperture")
                    .foregroundStyle(Color.mint)
                Text("对焦与曝光")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(camera.focusLocked && camera.exposureLocked ? "LOCKED" : "AUTO")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(camera.focusLocked && camera.exposureLocked
                                     ? Color.mint
                                     : Color.white.opacity(0.52))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.08), in: Capsule())
            }

            Text("先让画面自动合焦和测光，再锁住当前值；曝光补偿在锁定后仍然可以微调。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    camera.toggleFocusLock()
                } label: {
                    Label(camera.focusLocked ? "解锁对焦" : "锁定对焦",
                          systemImage: camera.focusLocked ? "lock.open" : "lock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionStyle())

                Button {
                    camera.toggleExposureLock()
                } label: {
                    Label(camera.exposureLocked ? "解锁曝光" : "锁定曝光",
                          systemImage: camera.exposureLocked ? "lock.open" : "sun.max")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionStyle())
            }
            .disabled(!camera.isRunning)

            Button {
                camera.toggleFocusAndExposureLock()
            } label: {
                Label(
                    camera.focusLocked && camera.exposureLocked
                        ? "恢复自动对焦与曝光"
                        : "同时锁定对焦与曝光",
                    systemImage: camera.focusLocked && camera.exposureLocked ? "lock.open" : "lock.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(!camera.isRunning)

            TuningSlider(
                title: "曝光补偿",
                value: Binding(
                    get: { camera.exposureBias },
                    set: { camera.setExposureBias($0) }
                ),
                range: -3...3,
                valueFormat: "%+.1f EV"
            )
            .disabled(!camera.isRunning)

            if let errorMessage = camera.focusExposureError {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(17)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text("处理后录像")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("把鱼眼矫正和锁定模式处理后的画面与现场声音保存为竖屏 MP4。麦克风只在录制时启用。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Button {
                if recorder.isRecording {
                    recorder.stop { camera.stopAudioCapture() }
                } else if !recorder.isFinishing {
                    camera.prepareAudioForRecording { hasAudio in
                        recorder.start(includeAudio: hasAudio) { started in
                            if !started { camera.stopAudioCapture() }
                        }
                    }
                }
            } label: {
                Label(
                    recorder.isFinishing ? "正在保存录像…" : (recorder.isRecording ? "停止并保存" : "开始录制稳定画面"),
                    systemImage: recorder.isRecording ? "stop.fill" : "record.circle"
                )
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(recorder.isRecording ? Color.red : Color.mint, in: RoundedRectangle(cornerRadius: 13))
                .foregroundStyle(recorder.isRecording ? Color.white : Color.black)
            }
            .disabled(recorder.isFinishing || !camera.isRunning)

            if let savedURL = recorder.savedURL {
                ShareLink(item: savedURL) {
                    Label("分享或存入相册", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionStyle())
            }

            if let errorMessage = recorder.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
            if let audioWarning = camera.audioWarning {
                Text(audioWarning)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(17)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
    }

    private var correctionControls: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("镜头几何校正")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("调节鱼眼投影参数，对照预览微调；设置会自动保存在本机")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Button {
                    settings = .preliminary
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mint)
                }
            }

            VStack(spacing: 14) {
                TuningSlider(title: "中心 X", value: $settings.centerX, range: 0.44...0.56, valueFormat: "%.3f")
                TuningSlider(title: "中心 Y", value: $settings.centerY, range: 0.44...0.56, valueFormat: "%.3f")
                TuningSlider(title: "径向畸变 K1", value: $settings.k1, range: -0.20...0.40, valueFormat: "%+.3f")
                TuningSlider(title: "径向畸变 K2", value: $settings.k2, range: -0.20...0.20, valueFormat: "%+.3f")
                TuningSlider(title: "输出视场角（横向）", value: $settings.horizontalFOV, range: 70...155, valueFormat: "%.0f°")
                TuningSlider(title: "镜头半视场角", value: $settings.lensHalfFOV, range: 45...85, valueFormat: "%.0f°")
                TuningSlider(title: "成像圈比例（相对短边）", value: $settings.imageCircleRatio, range: 0.70...1.60, valueFormat: "%.2f×")
            }

            Text("103° 是鱼眼矫正后的横向输出视场。75 mm 是图中机台外框边缘到内屏边缘的实体间距，用于估算机台距离；两者是独立参数。")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    settings.correctionEnabled.toggle()
                } label: {
                    Label(settings.correctionEnabled ? "关闭矫正" : "开启矫正", systemImage: "camera.filters")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionStyle())

                Button {
                    if let url = settings.exportURL() {
                        sharedProfile = LensProfileFile(url: url)
                    }
                } label: {
                    Label("导出参数", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionStyle())
            }
        }
        .padding(17)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
    }

    private var calibrationNote: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.mint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("机台实拍配置")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(String(format: "当前默认：输出视场 %.0f°、镜头半视场 %.0f°、成像圈 %.2f×。外夹镜头安装差异可用上方滑条微调。",
                            settings.horizontalFOV, settings.lensHalfFOV, settings.imageCircleRatio))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .background(Color.mint.opacity(0.075), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ShareProfileSheet: View {
    let url: URL

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Color.mint)
            Text("鱼眼校正参数已准备好")
                .font(.system(size: 18, weight: .bold))
            Text("导出 JSON 可备份当前镜头参数，换设备或重装后也能恢复。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ShareLink(item: url) {
                Label("分享 MaiLens-Lens-Profile.json", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.mint, in: RoundedRectangle(cornerRadius: 13))
                    .foregroundStyle(Color.black)
            }
        }
        .padding(24)
    }
}
