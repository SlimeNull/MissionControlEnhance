import os

enum Log {
    static let monitor = Logger(subsystem: "com.slimenull.MissionControlEnhance", category: "monitor")
    static let input = Logger(subsystem: "com.slimenull.MissionControlEnhance", category: "input")
    static let actions = Logger(subsystem: "com.slimenull.MissionControlEnhance", category: "actions")
}
