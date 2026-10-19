import Foundation
import MachO

/// Keeps the menu-bar app lean between jobs.
enum MemoryRelief {
    /// Physical footprint in MB (what Activity Monitor shows as "Memory").
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Heap bytes in use vs. reserved by malloc (MB).
    static func mallocMB() -> (inUse: Double, allocated: Double) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (Double(stats.size_in_use) / 1_048_576, Double(stats.size_allocated) / 1_048_576)
    }

    /// Called when the last job finishes: drop caches and hand freed heap pages back to the system.
    static func afterWork() {
        URLCache.shared.removeAllCachedResponses()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
