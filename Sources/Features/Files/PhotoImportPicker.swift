import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// 系统相册选择器（PHPickerViewController）：与旧版一致，选中后立刻把
/// provider 的临时表示导入目标目录，按 UTType 补全扩展名。
/// SwiftUI 的 photosPicker 在菜单收起时同样有呈现竞态，这里直接用 UIKit。
final class PhotoImportPicker: NSObject, PHPickerViewControllerDelegate {
    private let onFinish: (Int, String?) -> Void
    private let destination: String

    init(destination: String, onFinish: @escaping (Int, String?) -> Void) {
        self.destination = destination
        self.onFinish = onFinish
    }

    func makeController() -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = self
        return controller
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else {
            onFinish(0, nil)
            return
        }

        let destination = self.destination
        let group = DispatchGroup()
        let lock = NSLock()
        var imported = 0
        var firstFailure: String?

        for result in results {
            let provider = result.itemProvider
            var identifier: String?
            var preferredExtension: String?
            for candidate in provider.registeredTypeIdentifiers {
                guard let type = UTType(candidate), type.conforms(to: .image) else { continue }
                identifier = candidate
                preferredExtension = type.preferredFilenameExtension
                break
            }
            guard let identifier else {
                lock.lock()
                if firstFailure == nil { firstFailure = "存在无法读取的照片" }
                lock.unlock()
                continue
            }

            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                defer { group.leave() }
                guard let url, error == nil else {
                    lock.lock()
                    if firstFailure == nil {
                        firstFailure = error?.localizedDescription ?? "读取照片失败"
                    }
                    lock.unlock()
                    return
                }
                // provider 的临时表示只在回调期间有效：先拷进 App 自己的
                // 临时目录，再交给 ImportService。
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ff-photo-\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: staging,
                                                            withIntermediateDirectories: true)
                } catch {
                    lock.lock()
                    if firstFailure == nil { firstFailure = error.localizedDescription }
                    lock.unlock()
                    return
                }
                var name = provider.suggestedName ?? url.lastPathComponent
                if name.isEmpty { name = "imported" }
                if (name as NSString).pathExtension.isEmpty, let preferredExtension {
                    name += ".\(preferredExtension)"
                }
                let staged = staging.appendingPathComponent(name)
                let result: ImportResult
                if (try? FileManager.default.copyItem(at: url, to: staged)) != nil {
                    result = ImportService.importURL(staged, displayName: name,
                                                     toDirectory: destination)
                } else {
                    result = ImportResult(success: false, sourcePath: url.path,
                                          destinationPath: nil,
                                          error: ImportError.copyFailed("无法暂存照片"))
                }
                try? FileManager.default.removeItem(at: staging)

                lock.lock()
                if result.success {
                    imported += 1
                } else if firstFailure == nil {
                    firstFailure = result.error?.localizedDescription ?? name
                }
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [onFinish] in
            onFinish(imported, firstFailure)
        }
    }
}
