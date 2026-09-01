#scope_export

VkXlibSurfaceCreateFlagsKHR :: VkFlags;

VkXlibSurfaceCreateInfoKHR :: struct {
    sType: VkStructureType = .VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
    pNext: *void;
    flags: VkXlibSurfaceCreateFlagsKHR;
    display: *Display;
    window: Window;
}

PFN_vkCreateXlibSurfaceKHR :: #type (instance: VkInstance, pCreateInfo: *VkXlibSurfaceCreateInfoKHR, pAllocator: *VkAllocationCallbacks, surface: *VkSurfaceKHR) -> VkResult #c_call;

#scope_file

#import "X11";