// Domain types (Vec2, Rect, Stroke, Node, Connection, ...) now live in InkCore.
// Re-exported here so existing `import SpiderbrainKit` call sites keep working
// while the rest of the code migrates out of this legacy target.
@_exported import InkCore
