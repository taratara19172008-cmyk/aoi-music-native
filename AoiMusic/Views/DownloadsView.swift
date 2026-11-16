import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t("downloads"))
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .padding(.top, 14)
                if downloads.items.isEmpty {
                    Text(settings.t("no_downloads"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 30)
                }
                ForEach(Array(downloads.items.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 10) {
                        ArtworkImage(urlString: downloads.songStub(item).art(120, 120), size: 46, corner: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .foregroundStyle(player.current?.id == item.id ? settings.accent : .primary)
                            Text(item.artist + (item.album.isEmpty ? "" : " · \(item.album)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if player.current?.id == item.id {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(settings.accent)
                        }
                        Button {
                            downloads.remove(item)
                        } label: {
                            Image(systemName: "trash")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { player.playDownloaded(downloads.items, start: i, manager: downloads) }
                }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}
