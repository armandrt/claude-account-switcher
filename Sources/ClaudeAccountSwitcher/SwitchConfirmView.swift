import SwiftUI
import SwitcherCore

/// The ⌥-click dry run: who is being swapped, anything odd about it, and the
/// steps by name.  The plan goes back to the switcher so it can refuse if the
/// world moved in the meantime.
struct SwitchConfirmView: View {
    let plan: SwitchPlan
    let isBusy: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Switch account").font(.system(size: 13, weight: .semibold))
            Text(plan.headline)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)

            if plan.isNoOp {
                Warning(text: "already the active login")
            }
            ForEach(plan.warnings, id: \.self) { Warning(text: $0) }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step.title)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                Button("Switch to \(plan.to.name)", action: onConfirm)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                Button("Cancel", action: onCancel).controlSize(.small)
                if isBusy { ProgressView().controlSize(.small).scaleEffect(0.6) }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

/// The capture dry run.  The headline carries the email, which is the check.
struct CaptureConfirmView: View {
    let plan: CapturePlan
    let isBusy: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capture").font(.system(size: 13, weight: .semibold))
            Text(plan.headline)
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            Text(plan.slotExists ? "replaces \"\(plan.service)\"" : "creates \"\(plan.service)\"")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(plan.warnings, id: \.self) { Warning(text: $0) }
            HStack(spacing: 8) {
                Button("Capture as \(plan.name)", action: onConfirm)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                Button("Cancel", action: onCancel).controlSize(.small)
                if isBusy { ProgressView().controlSize(.small).scaleEffect(0.6) }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

/// An amber dot and a sentence saying what to do about it.
struct Warning: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(Color.orange).frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0.height }
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
