import SwiftUI

struct AISidebarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.aiMessages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                        }
                        if let streaming = viewModel.aiStreamingText, !streaming.isEmpty {
                            messageBubble(.init(role: "assistant", text: streaming))
                                .redacted(reason: .placeholder.opacity(0)) // ensure same layout
                        }
                    }
                    .padding(12)
                }
                .onChange(of: viewModel.aiMessages.count) { _ in
                    if let last = viewModel.aiMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
    }

    private var header: some View {
        HStack {
            Label("AI", systemImage: "brain.head.profile")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if viewModel.aiIsStreaming {
                ProgressView()
                    .scaleEffect(0.7)
            }
            Button {
                viewModel.cancelAIStream()
            } label: {
                Image(systemName: "stop.circle")
            }
            .help("Stop streaming")
            .disabled(!viewModel.aiIsStreaming)

            Button {
                viewModel.clearAIConversation()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear conversation")
        }
        .padding(8)
    }

    private func messageBubble(_ msg: AppViewModel.AIMessage) -> some View {
        HStack {
            if msg.role == "assistant" {
                bubble(text: msg.text, color: Color(NSColor.windowBackgroundColor), align: .leading)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                bubble(text: msg.text, color: Color.accentColor.opacity(0.18), align: .trailing)
            }
        }
    }

    private enum Align { case leading, trailing }
    private func bubble(text: String, color: Color, align: Align) -> some View {
        Text(text)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }
}