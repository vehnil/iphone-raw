import SwiftUI
import UIKit

/// Photos-style scrubber: narrow slices of every photo; the one under the centre
/// expands to its real shape and its neighbours move aside to make room. Built on
/// UICollectionView because the layout is recomputed on every scroll frame.
///
/// Scrolling maps to photos on an even pitch (the expansion only shifts frames),
/// so the photo under the centre is exact at any speed. While the user scrubs it
/// is reported through `onScrub`; when scrubbing ends it's selected and `onScrub(nil)`.
struct Filmstrip: UIViewRepresentable {
    let photos: [URL]
    /// Parallel to `photos`, so thumbnails reflect each photo's look.
    let settings: [DevelopSettings]
    let current: URL?
    let onScrub: (URL?) -> Void
    let onSelect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> StripView {
        let layout = FilmstripLayout()
        let view = StripView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.decelerationRate = .fast
        view.register(FilmstripCell.self, forCellWithReuseIdentifier: FilmstripCell.identifier)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        layout.expandedWidth = { [weak coordinator = context.coordinator] index in
            coordinator?.expandedWidth(at: index) ?? FilmstripLayout.height * 0.75
        }
        view.onBoundsChange = { [weak coordinator = context.coordinator] in coordinator?.boundsChanged() }
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: StripView, context: Context) {
        context.coordinator.update(with: self)
    }

    final class StripView: UICollectionView {
        var onBoundsChange: (() -> Void)?
        private var lastWidth: CGFloat = 0

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width != lastWidth else { return }
            lastWidth = bounds.width
            onBoundsChange?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        weak var view: StripView?
        private var parent: Filmstrip?
        private var aspects: [URL: CGFloat] = [:]
        private var scrubIndex: Int?
        private let haptics = UISelectionFeedbackGenerator()

        private var photos: [URL] { parent?.photos ?? [] }

        private var isUserScrolling: Bool {
            guard let view else { return false }
            return view.isTracking || view.isDragging || view.isDecelerating
        }

        func update(with newParent: Filmstrip) {
            let old = parent
            parent = newParent
            guard let view else { return }

            if old?.photos != newParent.photos {
                view.reloadData()
            } else if let old, old.settings != newParent.settings {
                let changed = newParent.settings.indices.filter { $0 >= old.settings.count || old.settings[$0] != newParent.settings[$0] }
                view.reconfigureItems(at: changed.map { IndexPath(item: $0, section: 0) })
            }

            // Follow the pager unless the user is driving the strip.
            if !isUserScrolling, scrubIndex == nil {
                center(on: newParent.current, animated: old != nil && view.window != nil)
            }
        }

        func boundsChanged() {
            guard let view else { return }
            let inset = max(0, (view.bounds.width - FilmstripLayout.sliceWidth) / 2)
            view.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            center(on: parent?.current, animated: false)
        }

        func expandedWidth(at index: Int) -> CGFloat {
            let aspect = photos.indices.contains(index) ? aspects[photos[index]] ?? 0.75 : 0.75
            return FilmstripLayout.height * aspect
        }

        // MARK: Positions

        /// Content offset that puts photo `index` under the centre.
        private func offset(for index: Int) -> CGFloat {
            guard let view else { return 0 }
            return CGFloat(index) * FilmstripLayout.pitch + FilmstripLayout.sliceWidth / 2 - view.bounds.width / 2
        }

        private func index(at offset: CGFloat) -> Int {
            guard let view, !photos.isEmpty else { return 0 }
            let position = (offset + view.bounds.width / 2 - FilmstripLayout.sliceWidth / 2) / FilmstripLayout.pitch
            return min(max(Int(position.rounded()), 0), photos.count - 1)
        }

        private func center(on url: URL?, animated: Bool) {
            guard let view, view.bounds.width > 0, let url, let index = photos.firstIndex(of: url) else { return }
            let target = offset(for: index)
            guard abs(view.contentOffset.x - target) > 0.5 else { return }
            view.setContentOffset(CGPoint(x: target, y: 0), animated: animated)
        }

        // MARK: Scrubbing

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isUserScrolling, !photos.isEmpty else { return }
            let index = index(at: scrollView.contentOffset.x)
            guard index != scrubIndex else { return }
            scrubIndex = index
            haptics.selectionChanged()
            parent?.onScrub(photos[index])
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            haptics.prepare()
        }

        /// Snaps a fling so a photo lands exactly in the centre.
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            targetContentOffset.pointee.x = offset(for: index(at: targetContentOffset.pointee.x))
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishScrubbing() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishScrubbing()
        }

        private func finishScrubbing() {
            guard let scrubIndex, photos.indices.contains(scrubIndex) else { return }
            self.scrubIndex = nil
            parent?.onSelect(photos[scrubIndex])
            parent?.onScrub(nil)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard photos.indices.contains(indexPath.item) else { return }
            parent?.onSelect(photos[indexPath.item])
        }

        // MARK: Data source

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            photos.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilmstripCell.identifier, for: indexPath) as! FilmstripCell
            if let parent, parent.photos.indices.contains(indexPath.item) {
                let url = parent.photos[indexPath.item]
                cell.show(url, settings: parent.settings[indexPath.item]) { [weak self] aspect in
                    self?.aspectLoaded(aspect, for: url)
                }
            }
            return cell
        }

        private func aspectLoaded(_ aspect: CGFloat, for url: URL) {
            guard aspects[url] != aspect else { return }
            aspects[url] = aspect
            view?.collectionViewLayout.invalidateLayout()
        }
    }
}

/// Even pitch for scrolling; the slice nearest the centre widens by up to its
/// full aspect (plus a gap each side), shared between the two nearest slices
/// mid-scrub, and everything else moves aside so nothing overlaps.
final class FilmstripLayout: UICollectionViewLayout {
    static let height: CGFloat = 42
    static let sliceWidth: CGFloat = 22
    static let spacing: CGFloat = 2
    static let gap: CGFloat = 5
    static let pitch = sliceWidth + spacing

    var expandedWidth: (Int) -> CGFloat = { _ in FilmstripLayout.height * 0.75 }

    private var count: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }

    override var collectionViewContentSize: CGSize {
        CGSize(width: max(0, CGFloat(count) * Self.pitch - Self.spacing), height: Self.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard count > 0 else { return [] }
        let state = expansion()
        // Frames can shift by about one expanded width, so widen the search.
        let margin = Self.height * 2
        let first = max(0, Int(((rect.minX - margin) / Self.pitch).rounded(.down)))
        let last = min(count - 1, Int(((rect.maxX + margin) / Self.pitch).rounded(.up)))
        guard first <= last else { return [] }
        return (first...last).map { attributes(at: $0, state) }.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes(at: indexPath.item, expansion())
    }

    private struct Expansion {
        /// Fractional index under the centre.
        var position: CGFloat
        /// Extra width (including gaps) for the two slices around `position`.
        var extra: [Int: CGFloat]
        /// How far everything is shifted left so the centre stays put.
        var shift: CGFloat
    }

    private func expansion() -> Expansion {
        guard let view = collectionView else { return Expansion(position: 0, extra: [:], shift: 0) }
        let position = (view.contentOffset.x + view.bounds.width / 2 - Self.sliceWidth / 2) / Self.pitch
        let below = Int(position.rounded(.down))
        var extra: [Int: CGFloat] = [:]
        var shift: CGFloat = 0
        for index in [below, below + 1] where (0..<count).contains(index) {
            let weight = max(0, 1 - abs(CGFloat(index) - position))
            let amount = weight * (expandedWidth(index) - Self.sliceWidth + 2 * Self.gap)
            extra[index] = amount
            // The part of a slice's growth left of the centre pushes everything before it left.
            shift += amount * min(max(position - CGFloat(index) + 0.5, 0), 1)
        }
        return Expansion(position: position, extra: extra, shift: shift)
    }

    private func attributes(at index: Int, _ state: Expansion) -> UICollectionViewLayoutAttributes {
        let weight = max(0, 1 - abs(CGFloat(index) - state.position))
        let grownBefore = state.extra.filter { $0.key < index }.values.reduce(0, +)
        let width = Self.sliceWidth + (state.extra[index] ?? 0) - 2 * Self.gap * weight
        let x = CGFloat(index) * Self.pitch + grownBefore - state.shift + Self.gap * weight

        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = CGRect(x: x, y: 0, width: max(Self.sliceWidth, width), height: Self.height)
        return attributes
    }
}

final class FilmstripCell: UICollectionViewCell {
    static let identifier = "FilmstripCell"

    private let imageView = UIImageView()
    private var url: URL?
    private var loading: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.2, alpha: 1)
        contentView.layer.cornerRadius = 2
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        imageView.image = nil
    }

    func show(_ url: URL, settings: DevelopSettings, onAspect: @escaping (CGFloat) -> Void) {
        self.url = url
        loading?.cancel()
        if let cached = RawRenderer.cachedThumbnail(for: url, settings: settings) {
            imageView.image = cached
            onAspect(cached.size.width / cached.size.height)
            return
        }
        loading = Task { @MainActor [weak self] in
            // Cancelled on reuse, so a fast scrub skips slices it has already passed.
            guard let image = await RawRenderer.thumbnail(for: url, settings: settings),
                  let self, !Task.isCancelled, self.url == url else { return }
            self.imageView.image = image
            onAspect(image.size.width / image.size.height)
        }
    }
}
