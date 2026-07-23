import SwiftUI

private enum VoiceVisualAccentKind: Equatable {
    case strongPulse
    case colorShift
}

private struct VoiceVisualAccent: Equatable {
    let id: UUID
    let kind: VoiceVisualAccentKind
    let meshPointIndex: Int
    let offset: SIMD2<Float>
    let intensity: Double
    let startedAt: TimeInterval
}

// MARK: - 小球调参实验台
//
// TunableOrb 逐行复刻 DiffuseOrb 的渲染逻辑，唯一区别是把原本硬编码的
// 常量全部提成可调参数（默认值 = 源码原值）。因为用的是真实的
// MeshGradient + .perceptual 混色，颜色与真机 100% 一致。
// ======================================================================

/// 一个可调常量的定义：绑定的 keyPath、标题、说明、范围、源码位置。
private struct OrbParam: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let source: String
    let range: ClosedRange<Double>
    let keyPath: WritableKeyPath<OrbTuning, Double>
}

/// 所有可调常量的当前值。默认值即 DiffuseOrb / PrimaryInteractionButton 源码值。
private struct OrbTuning: Equatable {
    var activity: Double = 1              // PrimaryInteractionButton.animationActivity
    var visualLevel: Double = 0           // 呼吸输入（0~1），真机来自 driver.normalizedLevel
    var breathing: Double = 0.012         // breathing = level * 0.012
    var phaseBase: Double = 0.34          // phase = time*(0.34 + 0.28*activity)
    var phaseActivity: Double = 0.28
    var driftBase: Double = 0.035         // drift = 0.035 + 0.07*activity
    var driftActivity: Double = 0.07
    var pulseBase: Double = 0.035         // pulse = env*(0.035 + 0.02*intensity)
    var pulseIntensity: Double = 0.02
    var baseScale: Double = 1.06          // .scaleEffect(1.06)
    var strokeOpacity: Double = 0.28      // .stroke(.white.opacity(0.28), lineWidth:1)
    var strokeWidth: Double = 1
    var attackStrong: Double = 0.09       // accentEnvelope strongPulse
    var releaseStrong: Double = 0.5
    var attackColor: Double = 0.07        // accentEnvelope colorShift
    var releaseColor: Double = 0.34
    var softeningBump: Double = 0.3       // softening[i] + env*0.3
    var shadowOpacity: Double = 0.25      // .shadow(color: tint.opacity(0.25), …)
    var shadowRadius: Double = 0.12       // radius = width*0.12
    var shadowY: Double = 0.05            // y = width*0.05
    var orbSize: Double = 260             // 显示直径（真机由布局算出 = contentWidth*0.32）
}

private struct OrbParamGroup: Identifiable {
    let id = UUID()
    let title: String
    let params: [OrbParam]
}

private let orbParamGroups: [OrbParamGroup] = [
    OrbParamGroup(title: "尺寸 · 状态", params: [
        OrbParam(title: "小球尺寸 (px)", detail: "实验台用绝对像素方便看细节。真机里没有固定尺寸，由布局算出：actionButtonWidth = contentWidth × 0.32，再 .aspectRatio(1,.fit) 保持正方形。", source: "ContentView.swift:1511, 2010", range: 80...520, keyPath: \.orbSize),
        OrbParam(title: "活跃度 activity", detail: "“这颗球有多活跃”的总开关，同时喂给流动速度和涌动幅度。运行时由连接状态决定：已连接 1 / 准备中 0.62 / 空闲·出错 0.34。", source: "ContentView.swift:2034-2043", range: 0...1, keyPath: \.activity),
        OrbParam(title: "呼吸输入 visualLevel", detail: "呼吸的输入音量（0~1）。真机来自 voiceVisualDriver.normalizedLevel。这里手动拉动可模拟说话音量。", source: "ContentView.swift:1995, 2071", range: 0...1, keyPath: \.visualLevel),
    ]),
    OrbParamGroup(title: "外观 · 流动 · 呼吸 · 脉冲", params: [
        OrbParam(title: "呼吸系数 (×level)", detail: "breathing = clamp(visualLevel,0,1) × 0.012，最终 scale = 1 + breathing + pulse。最大仅 1.2% 缩放，刻意极克制。", source: "ContentView.swift:2071, 2088", range: 0...0.2, keyPath: \.breathing),
        OrbParam(title: "流动基频", detail: "phase = time × (0.34 + 0.28×activity)。phase 决定网格顶点里 sin/cos 转多快 → 渐变流动快慢。这是常数项 0.34。", source: "ContentView.swift:2066", range: 0...2, keyPath: \.phaseBase),
        OrbParam(title: "流动·活跃增益", detail: "phase 公式里乘 activity 的系数 0.28。已连接流速 0.62，空闲 ≈0.44。", source: "ContentView.swift:2066", range: 0...2, keyPath: \.phaseActivity),
        OrbParam(title: "涌动基幅", detail: "drift = 0.035 + 0.07×activity，控制顶点漂移幅度 → 涌动起伏大小。内部 4 点乘满 drift，边缘点乘 drift×0.4~0.45，所以涌动集中在球心。", source: "ContentView.swift:2143", range: 0...0.3, keyPath: \.driftBase),
        OrbParam(title: "涌动·活跃增益", detail: "drift 公式里乘 activity 的系数 0.07。已连接 drift=0.105，空闲 ≈0.059。", source: "ContentView.swift:2143", range: 0...0.3, keyPath: \.driftActivity),
        OrbParam(title: "脉冲缩放·基", detail: "pulse = accentEnvelope × (0.035 + 0.02×intensity)，仅 strongPulse 时生效。让强脉冲时整球在呼吸之外额外“噗”地弹一下。", source: "ContentView.swift:2068-2070", range: 0...0.3, keyPath: \.pulseBase),
        OrbParam(title: "脉冲缩放·强度增益", detail: "pulse 公式里乘 intensity 的系数 0.02。", source: "ContentView.swift:2069", range: 0...0.3, keyPath: \.pulseIntensity),
        OrbParam(title: "基础放大 baseScale", detail: ".scaleEffect(1.06)，仅 iOS18 MeshGradient 分支有。让 4×4 网格略微溢出圆形裁剪边界，防止顶点内移时露出背景白边。", source: "ContentView.swift:2082", range: 1...1.3, keyPath: \.baseScale),
        OrbParam(title: "描边不透明度", detail: "Circle().stroke(.white.opacity(0.28), lineWidth:1) — 球边缘那圈白色高光轮廓。", source: "ContentView.swift:2084-2085", range: 0...1, keyPath: \.strokeOpacity),
        OrbParam(title: "描边宽度 (px)", detail: "同上 stroke 的 lineWidth，源码为 1。", source: "ContentView.swift:2085", range: 0...5, keyPath: \.strokeWidth),
        OrbParam(title: "强脉冲 attack (s)", detail: "accentEnvelope 起亮时长（smoothstep 快速亮起）。strongPulse 为 0.09s。", source: "ContentView.swift:2187", range: 0...0.5, keyPath: \.attackStrong),
        OrbParam(title: "强脉冲 release (s)", detail: "accentEnvelope 熄灭时长（(1-p)² 缓慢退去）。strongPulse 为 0.5s，起得稳退得慢。", source: "ContentView.swift:2188", range: 0...2, keyPath: \.releaseStrong),
        OrbParam(title: "色移 attack (s)", detail: "colorShift 的起亮时长 0.07s，比强脉冲更轻快。", source: "ContentView.swift:2187", range: 0...0.5, keyPath: \.attackColor),
        OrbParam(title: "色移 release (s)", detail: "colorShift 的熄灭时长 0.34s。", source: "ContentView.swift:2188", range: 0...2, keyPath: \.releaseColor),
        OrbParam(title: "高光混白增量", detail: "脉冲命中的顶点额外混白：softening[i] += accentEnvelope × 0.3。视觉上就是那一处“泛白发亮”。", source: "ContentView.swift:2106-2109", range: 0...1, keyPath: \.softeningBump),
    ]),
    OrbParamGroup(title: "阴影辉光（按钮层）", params: [
        OrbParam(title: "阴影不透明度", detail: ".shadow(color: tint.opacity(0.25), …)。关键：阴影用 tint 色而非黑色 → 彩色辉光，让球像浮着发光。", source: "ContentView.swift:2000-2004", range: 0...1, keyPath: \.shadowOpacity),
        OrbParam(title: "阴影半径系数 (×w)", detail: "shadow radius = width × 0.12，相对球宽，球放大时辉光同步放大。", source: "ContentView.swift:2002", range: 0...0.4, keyPath: \.shadowRadius),
        OrbParam(title: "阴影 Y 偏移系数 (×w)", detail: "shadow y = width × 0.05。", source: "ContentView.swift:2003", range: 0...0.3, keyPath: \.shadowY),
    ]),
]

/// DiffuseOrb 的参数化复刻。渲染逻辑逐行对应源码 :2058-2200，仅把常量换成 tuning。
private struct TunableOrb: View {
    let tint: Color
    let tuning: OrbTuning
    let softening: [Double]
    let accent: VoiceVisualAccent?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = time * (tuning.phaseBase + tuning.phaseActivity * tuning.activity)
            let env = accentEnvelope(at: time)
            let pulse = accent?.kind == .strongPulse
                ? env * (tuning.pulseBase + tuning.pulseIntensity * (accent?.intensity ?? 0))
                : 0
            let breathing = min(1, max(0, tuning.visualLevel)) * tuning.breathing

            if #available(iOS 18.0, *) {
                MeshGradient(
                    width: 4, height: 4,
                    points: meshPoints(phase: phase, env: env),
                    colors: meshColors(env: env),
                    background: .white,
                    smoothsColors: true
                )
                .scaleEffect(tuning.baseScale)
                .overlay { Circle().stroke(.white.opacity(tuning.strokeOpacity), lineWidth: tuning.strokeWidth) }
                .clipShape(Circle())
                .scaleEffect(1 + breathing + pulse)
            } else {
                Circle().fill(tint).scaleEffect(1 + breathing + pulse)
            }
        }
    }

    @available(iOS 18.0, *)
    private func meshColors(env: Double) -> [Color] {
        var soft = softening
        if let accent {
            soft[accent.meshPointIndex] = min(1, soft[accent.meshPointIndex] + env * tuning.softeningBump)
        }
        return soft.map { tint.mix(with: .white, by: $0, in: .perceptual) }
    }

    private func accentEnvelope(at time: TimeInterval) -> Double {
        guard let accent else { return 0 }
        let elapsed = max(0, time - accent.startedAt)
        let attack = accent.kind == .strongPulse ? tuning.attackStrong : tuning.attackColor
        let release = accent.kind == .strongPulse ? tuning.releaseStrong : tuning.releaseColor
        if elapsed < attack {
            let p = elapsed / attack
            return p * p * (3 - 2 * p)
        }
        let p = min(1, (elapsed - attack) / release)
        return (1 - p) * (1 - p)
    }

    private func meshPoints(phase: Double, env: Double) -> [SIMD2<Float>] {
        let drift = tuning.driftBase + tuning.driftActivity * tuning.activity
        func pt(_ x: Double, _ y: Double) -> SIMD2<Float> { SIMD2(Float(x), Float(y)) }
        var points = [
            pt(0, 0),
            pt(0.33 + sin(phase * 0.73) * drift * 0.45, 0),
            pt(0.67 + cos(phase * 0.81) * drift * 0.45, 0),
            pt(1, 0),
            pt(0, 0.33 + cos(phase * 0.69) * drift * 0.4),
            pt(0.33 + cos(phase * 0.91) * drift, 0.33 + sin(phase * 1.13) * drift),
            pt(0.67 + sin(phase * 1.19) * drift, 0.33 + cos(phase * 0.83) * drift),
            pt(1, 0.33 + sin(phase * 0.77) * drift * 0.4),
            pt(0, 0.67 + sin(phase * 0.87) * drift * 0.4),
            pt(0.33 + sin(phase * 0.71) * drift, 0.67 + cos(phase * 1.07) * drift),
            pt(0.67 + cos(phase * 0.67) * drift, 0.67 + sin(phase * 0.89) * drift),
            pt(1, 0.67 + cos(phase * 0.93) * drift * 0.4),
            pt(0, 1),
            pt(0.33 + cos(phase * 0.79) * drift * 0.45, 1),
            pt(0.67 + sin(phase * 0.75) * drift * 0.45, 1),
            pt(1, 1)
        ]
        if let accent {
            points[accent.meshPointIndex] += accent.offset * Float(env)
        }
        return points
    }
}

/// 调参台主视图：上半预览小球，下半是分组 Slider（每条带说明与源码位置）。
struct OrbTuningLab: View {
    @State private var tuning = OrbTuning()
    @State private var tintHue: Double = 0.34
    @State private var tintSat: Double = 0.65
    @State private var tintBri: Double = 0.90
    @State private var softening: [Double] = [
        0.12, 0.18, 0.3, 0.22,
        0.25, 0.38, 0.56, 0.32,
        0.78, 0.62, 0.88, 0.76,
        0.9, 0.94, 1, 0.92
    ]
    @State private var accent: VoiceVisualAccent?
    @State private var darkBackground = true

    private var tint: Color {
        Color(hue: tintHue, saturation: tintSat, brightness: tintBri)
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(height: 320)
                .frame(maxWidth: .infinity)
                .background(darkBackground ? Color.black : Color(white: 0.95))
                .clipped()
            Divider()
            controls
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var preview: some View {
        ZStack {
            TunableOrb(tint: tint, tuning: tuning, softening: softening, accent: accent)
                .frame(width: tuning.orbSize, height: tuning.orbSize)
                .shadow(
                    color: tint.opacity(tuning.shadowOpacity),
                    radius: tuning.orbSize * tuning.shadowRadius,
                    y: tuning.orbSize * tuning.shadowY
                )
            VStack {
                HStack {
                    Toggle("深色底", isOn: $darkBackground)
                        .labelsHidden()
                    Text(darkBackground ? "深色底" : "浅色底").font(.caption2)
                    Spacer()
                    Button("色移") { fireAccent(.colorShift) }
                        .font(.caption2).buttonStyle(.bordered)
                    Button("强脉冲") { fireAccent(.strongPulse) }
                        .font(.caption2).buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12).padding(.top, 8)
                Spacer()
            }
        }
    }

    private func fireAccent(_ kind: VoiceVisualAccentKind) {
        let idxs = [5, 6, 9, 10]
        let angle = Double.random(in: 0..<(2 * .pi))
        let base: Float = kind == .strongPulse ? 0.06 : 0.03
        let range: Float = kind == .strongPulse ? 0.035 : 0.02
        let intensity = Double.random(in: 0.4...1)
        let amp = base + range * Float(intensity)
        accent = VoiceVisualAccent(
            id: UUID(),
            kind: kind,
            meshPointIndex: idxs.randomElement()!,
            offset: SIMD2(cos(Float(angle)) * amp, sin(Float(angle)) * amp),
            intensity: intensity,
            startedAt: Date().timeIntervalSinceReferenceDate
        )
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                tintSection
                ForEach(orbParamGroups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(group.title)
                            .font(.headline)
                        ForEach(group.params) { param in
                            sliderRow(param)
                        }
                    }
                }
                softeningSection
                Button(role: .destructive) {
                    tuning = OrbTuning()
                    softening = [
                        0.12, 0.18, 0.3, 0.22,
                        0.25, 0.38, 0.56, 0.32,
                        0.78, 0.62, 0.88, 0.76,
                        0.9, 0.94, 1, 0.92
                    ]
                    tintHue = 0.34; tintSat = 0.65; tintBri = 0.90
                } label: {
                    Text("全部重置为源码值").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private var tintSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("基色 tint").font(.headline)
            Text("整颗球的颜色都由这一个基色按不同比例混白得到。运行时由 buttonTint 按语音状态给：已连接 .green / 准备中 .orange / 空闲·出错 .accentColor。")
                .font(.caption).foregroundStyle(.secondary)
            Text("📄 ContentView.swift:2023-2032, 2116").font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Button("已连接 绿") { tintHue = 0.34; tintSat = 0.60; tintBri = 0.90 }
                Button("准备中 橙") { tintHue = 0.09; tintSat = 0.95; tintBri = 1.0 }
                Button("空闲 蓝") { tintHue = 0.58; tintSat = 0.90; tintBri = 1.0 }
                Button("深绿(Preview)") { tintHue = 0.34; tintSat = 0.88; tintBri = 0.62 }
            }
            .font(.caption2).buttonStyle(.bordered)
            labeledSlider("Hue 色相", value: $tintHue, range: 0...1)
            labeledSlider("Saturation 饱和", value: $tintSat, range: 0...1)
            labeledSlider("Brightness 明度", value: $tintBri, range: 0...1)
        }
    }

    private func sliderRow(_ param: OrbParam) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(param.title).font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.3f", tuning[keyPath: param.keyPath]))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { tuning[keyPath: param.keyPath] },
                    set: { tuning[keyPath: param.keyPath] = $0 }
                ),
                in: param.range
            )
            Text(param.detail).font(.caption).foregroundStyle(.secondary)
            Text("📄 " + param.source).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44)
        }
    }

    private var softeningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Softening 混白网格（16 值）").font(.headline)
            Text("对应 4×4 网格 16 个顶点的混白量：0=纯 tint，1=纯白。默认从左上(≈纯色)到右下(≈纯白)，形成“光从右下漫射”的立体感。混色在 .perceptual(感知均匀)空间做。")
                .font(.caption).foregroundStyle(.secondary)
            Text("📄 ContentView.swift:2099-2104").font(.caption2).foregroundStyle(.tertiary)
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { col in
                        let i = row * 4 + col
                        VStack(spacing: 2) {
                            Slider(
                                value: Binding(
                                    get: { softening[i] },
                                    set: { softening[i] = $0 }
                                ),
                                in: 0...1
                            )
                            Text(String(format: "%.2f", softening[i]))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

#Preview("🎛 小球调参实验台") {
    OrbTuningLab()
}

@main
struct OrbTuningLabApp: App {
    var body: some Scene {
        WindowGroup {
            OrbTuningLab()
        }
    }
}

