import AppKit
import PaneModel
import SwiftUI

@MainActor
final class StartPageModel: ObservableObject {
    struct Tile: Identifiable { let id: String; let title: String; let url: String; let icon: NSImage? }

    @Published var favorites: [Tile] = []
    @Published var recents: [Tile] = []
    @Published var engineName = "Google"
    @Published var focusToken = 0
    @Published var isPrivate = false
    @Published var accent: Color = .accentColor
    var onSearch: (String) -> Void = { _ in }
    var onOpen: (String, _ newTab: Bool) -> Void = { _, _ in }
}

struct StartPageView: View {
    @ObservedObject var model: StartPageModel
    @State private var query = ""
    @FocusState private var focused: Bool
    @State private var appeared = false

    private var accent: Color { model.accent }

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            RadialGradient(colors: [accent.opacity(0.20), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color.purple.opacity(0.14), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 650)
            ScrollView {
                VStack(spacing: 34) {
                    VStack(spacing: 6) {
                        if model.isPrivate { Image(systemName: "lock.shield.fill").font(.system(size: 34)).foregroundStyle(.purple).padding(.bottom, 4) }
                        Text(model.isPrivate ? tr("Private Window") : StartPageContent.greeting()).font(.system(size: 38, weight: .semibold, design: .rounded))
                        Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day().locale(AppLanguage.currentLocale)))
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    .padding(.top, 70)
                    .modifier(Rise(appeared: appeared, index: 0))

                    searchField.modifier(Rise(appeared: appeared, index: 1))

                    if model.isPrivate { privateNotice }
                    if model.isPrivate { EmptyView() } else if model.favorites.isEmpty && model.recents.isEmpty {
                        Text("Your favorites and the sites you visit will appear here.")
                            .foregroundStyle(.tertiary).padding(.top, 8)
                    }
                    if !model.isPrivate && !model.favorites.isEmpty { favorites.modifier(Rise(appeared: appeared, index: 2)) }
                    if !model.isPrivate && !model.recents.isEmpty { recents.modifier(Rise(appeared: appeared, index: 3)) }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 32).padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: model.focusToken) { _, _ in focused = true }
        .onAppear { focused = true; withAnimation { appeared = true } }
    }

    private var privateNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pane won't remember the sites you visit, your searches or your cookies once you close this window.", systemImage: "eye.slash.fill")
            Label("Downloads and bookmarks you make are not part of that: files stay in your Downloads folder.", systemImage: "arrow.down.circle")
            Label("Your internet provider, employer and the sites themselves can still see what you do.", systemImage: "globe")
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.purple.opacity(0.08)) }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search \(model.engineName) or enter address", text: $query)
                .textFieldStyle(.plain).font(.system(size: 18))
                .focused($focused)
                .accessibilityLabel("Search or enter address")
                .onSubmit(go)
            if !query.isEmpty {
                Button(action: go) { Image(systemName: "arrow.right.circle.fill").font(.system(size: 22)).foregroundStyle(accent) }
                    .buttonStyle(.plain).transition(.scale.combined(with: .opacity)).accessibilityLabel("Go")
            }
        }
        .padding(.horizontal, 20).frame(height: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(focused ? accent.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: focused ? 2 : 1))
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        .animation(.snappy(duration: 0.2), value: focused)
        .animation(.snappy(duration: 0.2), value: query.isEmpty)
    }

    private func go() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        query = ""
        model.onSearch(q)
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Favorites")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 18)], spacing: 22) {
                ForEach(model.favorites) { tile in
                    FavoriteTile(tile: tile) { model.onOpen(tile.url, NSEvent.modifierFlags.contains(.command)) }
                }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Recently visited")
            VStack(spacing: 0) {
                ForEach(model.recents) { tile in
                    RecentRow(tile: tile) { model.onOpen(tile.url, NSEvent.modifierFlags.contains(.command)) }
                    if tile.id != model.recents.last?.id { Divider().padding(.leading, 52) }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private func header(_ s: String) -> some View {
        Text(LocalizedStringKey(s)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FavoriteTile: View {
    let tile: StartPageModel.Tile
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(hover ? 0.2 : 0.1))
                    if let icon = tile.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        Text(String(tile.title.prefix(1)).uppercased())
                            .font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(hover ? 0.16 : 0.06), radius: hover ? 12 : 5, y: hover ? 5 : 2)
                Text(tile.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 100)
            }
            .scaleEffect(hover ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tile.url)
        .accessibilityLabel(tile.title)
    }
}

private struct RecentRow: View {
    let tile: StartPageModel.Tile
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let icon = tile.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                    else { Image(systemName: "globe").foregroundStyle(.secondary) }
                }
                .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.title).lineLimit(1)
                    Text(URL(string: tile.url)?.host ?? tile.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(hover ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(tile.title)
    }
}


/// A hosting view that really is invisible to the mouse while hidden. (A plain NSHostingView keeps answering
/// hit tests when hidden, which silently swallowed every click meant for the web page underneath.)
final class StartPageHostingView: NSHostingView<StartPageView> {
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    required init(rootView: StartPageView) {
        super.init(rootView: rootView)
        sizingOptions = []  // SwiftUI must not dictate the window's size (it fed back into layout and could grow the window without bound)
    }
    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError() }
}

/// Fades and lifts a section into place; sections follow one another.
private struct Rise: ViewModifier {
    let appeared: Bool
    let index: Int
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.07), value: appeared)
    }
}
