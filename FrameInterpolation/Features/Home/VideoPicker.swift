import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import OSLog

/// 系统相册视频选择器封装（PHPickerViewController）
/// 选择后将临时文件拷贝到 App 沙盒临时目录，避免 PHPicker 临时文件被系统回收
struct VideoPicker: UIViewControllerRepresentable {
    private let logger = Logger(subsystem: "com.lambret.bz", category: "VideoPicker")
    /// 选择完成回调，返回拷贝后的沙盒临时文件 URL
    var onPick: (URL) -> Void
    /// 选择取消或失败回调
    var onCancel: (() -> Void)?

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - 协调器
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: VideoPicker

        init(_ parent: VideoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let result = results.first else {
                parent.onCancel?()
                return
            }

            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
                parent.logger.error("所选文件不是视频类型")
                parent.onCancel?()
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
                guard let self = self else { return }

                if let error = error {
                    self.parent.logger.error("加载视频文件失败: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async { self.parent.onCancel?() }
                    return
                }

                guard let url = url else {
                    self.parent.logger.error("视频 URL 为空")
                    DispatchQueue.main.async { self.parent.onCancel?() }
                    return
                }

                // PHPicker 返回的 URL 是系统临时文件，必须立即拷贝到自己的临时目录
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)

                do {
                    // 如果目标文件已存在则先删除
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try FileManager.default.removeItem(at: tempURL)
                    }
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    self.parent.logger.info("视频已拷贝到临时目录: \(tempURL.lastPathComponent, privacy: .public)")
                    DispatchQueue.main.async {
                        self.parent.onPick(tempURL)
                    }
                } catch {
                    self.parent.logger.error("拷贝视频到临时目录失败: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.main.async { self.parent.onCancel?() }
                }
            }
        }
    }
}
