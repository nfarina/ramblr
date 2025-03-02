import Foundation
import AppKit

class Logger {
    static let shared = Logger() // Singleton
    
    private let logFileURL: URL
    private let dateFormatter: DateFormatter
    
    // Log levels for different types of messages
    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case debug = "DEBUG"
    }
    
    private init() {
        // Set up log file in Documents directory
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.logFileURL = documentsDirectory.appendingPathComponent("WhisperDictate.log")
        
        // Configure date formatter
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        // Register for log message notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLogMessage(_:)),
            name: NSNotification.Name("LogMessage"),
            object: nil
        )
        
        // Log app start
        log("WhisperDictate application launched", level: .info)
    }
    
    // Main logging function
    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        
        print("📝 \(level.rawValue): \(message)")
        
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: logFileURL)
                fileHandle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } else {
                try logMessage.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Error writing to log file: \(error)")
        }
    }
    
    // Convenience methods for different log levels
    func info(_ message: String) {
        log(message, level: .info)
    }
    
    func warning(_ message: String) {
        log(message, level: .warning)
    }
    
    func error(_ message: String) {
        log(message, level: .error)
    }
    
    func debug(_ message: String) {
        log(message, level: .debug)
    }
    
    // Handle log messages sent via notification
    @objc private func handleLogMessage(_ notification: Notification) {
        if let message = notification.userInfo?["message"] as? String,
           let levelString = notification.userInfo?["level"] as? String,
           let level = LogLevel(rawValue: levelString) {
            log(message, level: level)
        } else if let message = notification.userInfo?["message"] as? String {
            // Default to info level if not specified
            log(message)
        }
    }
    
    // Open the log file in default text editor
    func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
    
    // Return the log file URL
    func getLogFileURL() -> URL {
        return logFileURL
    }
    
    // Clear the log file
    func clearLog() {
        do {
            try "".write(to: logFileURL, atomically: true, encoding: .utf8)
            log("Log file cleared", level: .info)
        } catch {
            print("Error clearing log file: \(error)")
        }
    }
    
    deinit {
        log("WhisperDictate application terminated", level: .info)
        NotificationCenter.default.removeObserver(self)
    }
}

// Static functions for easier global access
func logInfo(_ message: String) {
    Logger.shared.info(message)
}

func logWarning(_ message: String) {
    Logger.shared.warning(message)
}

func logError(_ message: String) {
    Logger.shared.error(message)
}

func logDebug(_ message: String) {
    Logger.shared.debug(message)
} 
