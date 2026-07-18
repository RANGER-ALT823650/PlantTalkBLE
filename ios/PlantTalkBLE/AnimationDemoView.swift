import SwiftUI

// 这个 Demo 仅展示以下这小段修饰符所产生的动画效果：
// .scaleEffect(hasArrived ? 1 : 0.9, anchor: .bottomTrailing)
// .offset(y: hasArrived ? 0 : 14)
// .opacity(hasArrived ? 1 : 0.72)

struct AnimationDemoView: View {
    @State private var hasArrived = false
    
    // 用于辅助观察：动画当前的状态说明
    private var animationStatus: String {
        hasArrived ? "已到达 (Target State)" : "未到达 (Initial State)"
    }

    var body: some View {
        VStack(spacing: 50) {
            Text("微动画效果演示")
                .font(.headline)
                .foregroundColor(.secondary)
            
            // 演示用的聊天气泡容器
            VStack(alignment: .trailing, spacing: 20) {
                // 模拟聊天气泡
                Text("🌱 嗨！今天的光照很棒，土壤湿度也很合适。")
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.green.gradient)
                    )
                    // ================== 核心动画代码 ==================
                    .scaleEffect(hasArrived ? 1 : 0.9, anchor: .bottomTrailing)
                    .offset(y: hasArrived ? 0 : 14)
                    .opacity(hasArrived ? 1 : 0.72)
                    .onAppear {
                        triggerAnimation()
                    }
                    // ================================================
                
                // 动画状态文字展示
                Text("当前状态: \(animationStatus)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(height: 120)
            
            // 控制面板：重新播放动画
            Button(action: replayAnimation) {
                Label("重新播放动画", systemImage: "play.circle.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
        }
        .padding()
    }
    
    // 触发动画
    private func triggerAnimation() {
        withAnimation(.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.3)) {
            hasArrived = true
        }
    }
    
    // 充值并重新播放
    private func replayAnimation() {
        // 先无动画恢复初始状态
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hasArrived = false
        }
        
        // 在下一个渲染帧触发过渡动画，以便能清晰看到完整的缩放和上浮过程
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            triggerAnimation()
        }
    }
}

#Preview {
    AnimationDemoView()
}
