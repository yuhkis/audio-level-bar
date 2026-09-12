import Darwin
import Foundation

public final class ProcessInstanceLock {
    public enum LockError: Error, Equatable {
        case missingApplicationSupportDirectory
        case invalidIdentifier
        case createDirectory(Int)
        case inspectDirectory(Int32)
        case invalidDirectory
        case directoryOwnerMismatch
        case hardenDirectory(Int32)
        case openFile(Int32)
        case inspectFile(Int32)
        case invalidFile
        case fileOwnerMismatch
        case hardenFile(Int32)
        case alreadyLocked
        case acquireLock(Int32)
    }

    private let fileDescriptor: Int32

    public convenience init(identifier: String) throws {
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LockError.missingApplicationSupportDirectory
        }
        let lockDirectory = applicationSupportDirectory
            .appendingPathComponent("Audio Level Bar", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
        try self.init(identifier: identifier, directory: lockDirectory)
    }

    public init(identifier: String, directory: URL) throws {
        let allowedIdentifierCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
        )
        guard
            !identifier.isEmpty,
            identifier.rangeOfCharacter(
                from: allowedIdentifierCharacters.inverted
            ) == nil
        else {
            throw LockError.invalidIdentifier
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw LockError.createDirectory((error as NSError).code)
        }

        var directoryInfo = stat()
        let inspectDirectoryResult = directory.withUnsafeFileSystemRepresentation {
            path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return lstat(path, &directoryInfo)
        }
        guard inspectDirectoryResult == 0 else {
            throw LockError.inspectDirectory(errno)
        }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw LockError.invalidDirectory
        }
        guard directoryInfo.st_uid == geteuid() else {
            throw LockError.directoryOwnerMismatch
        }
        let hardenDirectoryResult = directory.withUnsafeFileSystemRepresentation {
            path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return chmod(path, mode_t(S_IRWXU))
        }
        guard hardenDirectoryResult == 0 else {
            throw LockError.hardenDirectory(errno)
        }

        let lockURL = directory.appendingPathComponent(
            "\(identifier).instance.lock",
            isDirectory: false
        )
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return open(
                path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw LockError.openFile(errno)
        }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else {
            let lockError = errno
            close(descriptor)
            throw LockError.inspectFile(lockError)
        }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw LockError.invalidFile
        }
        guard fileInfo.st_uid == geteuid() else {
            close(descriptor)
            throw LockError.fileOwnerMismatch
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let lockError = errno
            close(descriptor)
            throw LockError.hardenFile(lockError)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK {
                throw LockError.alreadyLocked
            }
            throw LockError.acquireLock(lockError)
        }

        fileDescriptor = descriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
