import RelayCore
import SwiftUI

struct RoomInfoView: View {
    @Environment(\.matrixService) private var matrixService
    let roomId: String

    @State private var details: RoomDetails?

    var body: some View {
        Group {
            if let details {
                detailContent(details)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            details = await matrixService.roomDetails(roomId: roomId)
        }
    }

    // MARK: - Content

    private func detailContent(_ details: RoomDetails) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection(details)
                aboutSection(details)
                membersSection(details)
                footerSection(details)
            }
            .padding(.vertical, 16)
        }
    }

    // MARK: - Header

    private func headerSection(_ details: RoomDetails) -> some View {
        VStack(spacing: 6) {
            AvatarView(name: details.name, mxcURL: details.avatarURL, size: 80)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

            Text(details.name)
                .font(.title3)
                .fontWeight(.semibold)

            if let alias = details.canonicalAlias {
                Text(alias)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let topic = details.topic, !topic.isEmpty {
                Text(topic)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                badge(
                    icon: details.isEncrypted ? "lock.fill" : "lock.open",
                    label: details.isEncrypted ? "Encrypted" : "Unencrypted",
                    color: details.isEncrypted ? .green : .secondary
                )

                badge(
                    icon: details.isPublic ? "globe" : "lock.shield",
                    label: details.isPublic ? "Public" : "Private",
                    color: details.isPublic ? .blue : .secondary
                )

                if details.isDirect {
                    badge(icon: "person.fill", label: "Direct", color: .orange)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
    }

    private func badge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }

    // MARK: - About

    private func aboutSection(_ details: RoomDetails) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                infoRow(label: "Members", value: "\(details.memberCount)")

                if let alias = details.canonicalAlias {
                    Divider().padding(.vertical, 4)
                    infoRow(label: "Alias", value: alias)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Info", systemImage: "info.circle")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }

    // MARK: - Members

    private func membersSection(_ details: RoomDetails) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(details.members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        Divider().padding(.vertical, 4)
                    }
                    memberRow(member)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Members (\(details.memberCount))", systemImage: "person.2")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func memberRow(_ member: RoomMemberDetails) -> some View {
        HStack(spacing: 8) {
            AvatarView(
                name: member.displayName ?? member.userId,
                mxcURL: member.avatarURL,
                size: 28
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(member.displayName ?? member.userId)
                    .font(.callout)
                    .lineLimit(1)

                if member.displayName != nil {
                    Text(member.userId)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if member.role != .user {
                Text(member.role.rawValue.capitalized)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(member.role == .administrator ? .orange : .blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (member.role == .administrator ? Color.orange : Color.blue).opacity(0.1),
                        in: Capsule()
                    )
            }
        }
    }

    // MARK: - Footer

    private func footerSection(_ details: RoomDetails) -> some View {
        Text(details.id)
            .font(.caption2)
            .foregroundStyle(.quaternary)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.top, 4)
    }
}

#Preview {
    RoomInfoView(roomId: "!design:matrix.org")
        .environment(\.matrixService, PreviewMatrixService())
        .frame(height: 500)
}
