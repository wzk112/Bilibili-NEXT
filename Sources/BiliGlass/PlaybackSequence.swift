import Foundation

enum PlaybackSequence {
  static func parts(_ detail: Detail?) -> [PlaybackQueueItem] {
    guard let detail, detail.pages.count > 1 else { return [] }
    return detail.pages.enumerated().map {
      PlaybackQueueItem(bvid: detail.video.bvid, cid: $0.element.id,
        title: "P\($0.offset + 1) · \($0.element.title)")
    }
  }
  static func next(detail: Detail?, cid: Int, queue: [PlaybackQueueItem],
                   parts: Bool, collection: Bool) -> PlaybackQueueItem? {
    guard let detail else { return nil }
    let pages = self.parts(detail)
    if !pages.isEmpty && !pages.contains(where: { $0.cid == cid }) { return nil }
    if let index = pages.firstIndex(where: { $0.cid == cid }), pages.indices.contains(index + 1) {
      // Disabling part continuation must not skip the rest of the video for a collection item.
      return parts ? pages[index + 1] : nil
    }
    guard collection else { return nil }
    let items = queue.isEmpty ? detail.collection?.items ?? [] : queue
    let current = items.firstIndex { $0.bvid == detail.video.bvid && $0.cid == cid }
      ?? items.lastIndex { $0.bvid == detail.video.bvid }
    guard let index = current,
      items.indices.contains(index + 1) else { return nil }
    return items[index + 1]
  }
}
