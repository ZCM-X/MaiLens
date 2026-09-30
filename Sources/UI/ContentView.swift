import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraController()
    @StateObject private var autoLock = MachineAutoLockController()
    @StateObject private var horizonLock = HorizonLockController()
    @StateObject private var recorder = ProcessedVideoRecorder()
    @State private var settings = LensCorrectionSettings.load()
    @State private var sharedProfile: LensProfileFile?

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.048, blue: 0.055).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    cameraPreview
                    autoLockControls
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
        .sheet(item: $sharedProfile) { profile in
            ShareProfileSheet(url: profile.url)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                camera.start()
                horizonLock.start()
            } else {
                camera.stop()
                horizonLock.stop()
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
                Text("自动锁定机台")
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
                FisheyeCameraPreview(camera: camera, autoLock: autoLock, horizonLock: horizonLock, recorder: recorder, settings: settings)
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
                if horizonLock.isGimbalEnabled {
                    Button {
                        horizonLock.recenterGimbal()
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

            Text(camera.cameraName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        }
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 26))
    }

    private var autoLockControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Circle()
                    .fill(lockStatusColor)
                    .frame(width: 8, height: 8)
                Text(autoLock.status.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("全自动")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.mint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.mint.opacity(0.12), in: Capsule())
            }

            Text("模拟云台用陀螺仪抵消手机的左右转动、俯仰和横滚，并预留裁切空间。自动锁定再负责把机台中心和大小慢慢拉回目标位置。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    horizonLock.toggleGimbal()
                } label: {
                    Label(
                        horizonLock.isGimbalEnabled ? "关闭模拟云台" : "开启模拟云台",
                        systemImage: horizonLock.isGimbalEnabled ? "gyroscope" : "gyroscope"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionStyle())

                Button {
                    horizonLock.recenterGimbal()
                } label: {
                    Label("云台居中", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionStyle())
                .disabled(!horizonLock.isGimbalEnabled)
            }

            Button {
                autoLock.toggle()
            } label: {
                Label(autoLock.isEnabled ? "暂停自动锁定" : "开启自动锁定", systemImage: autoLock.isEnabled ? "pause.fill" : "viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionStyle())

            Button {
                horizonLock.toggle()
            } label: {
                Label(horizonLock.isEnabled ? "地平线稳定已开启" : "开启地平线稳定", systemImage: horizonLock.isEnabled ? "level.fill" : "level")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryActionStyle())
            .disabled(horizonLock.errorMessage != nil)
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
                Text("把鱼眼矫正、机台锁定和地平线稳定后的画面与现场声音保存为竖屏 MP4。麦克风只在录制时启用。")
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

    private var lockStatusColor: Color {
        switch autoLock.status {
        case .tracking: return .green
        case .lost: return .orange
        case .searching: return .mint
        case .paused: return .gray
        }
    }

    private var correctionControls: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("手动校正")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("对照预览里的直线微调，设置会自动保存在本机")
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
                TuningSlider(title: "输出视场角", value: $settings.horizontalFOV, range: 70...155, valueFormat: "%.0f°")
            }

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
                Text("已载入 MaiLens 镜头配置和机台实拍视场角。外夹鱼眼镜头的安装差异可用上方参数微调，修改会自动保存在本机。")
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
