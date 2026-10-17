//! Vulkan 1.3 renderer: dynamic rendering, depth buffer, mesh pipeline.
const std = @import("std");
const c = @import("c");
const math = @import("math.zig");
const mesh_mod = @import("mesh.zig");
const Window = @import("window.zig").Window;

const vert_spv align(4) = @embedFile("mesh.vert.spv").*;
const frag_spv align(4) = @embedFile("mesh.frag.spv").*;

const log = std.log.scoped(.gfx);

pub fn vk(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) {
        log.err("Vulkan error: {d}", .{result});
        return error.VulkanFailed;
    }
}

const max_images = 8;
const depth_format = c.VK_FORMAT_D32_SFLOAT;

/// Matches the push_constant block in mesh.vert.
const Push = extern struct {
    view_proj: [16]f32,
    model: [16]f32,
};

pub const Mesh = struct {
    vbuf: c.VkBuffer = null,
    vmem: c.VkDeviceMemory = null,
    ibuf: c.VkBuffer = null,
    imem: c.VkDeviceMemory = null,
    index_count: u32 = 0,
};

pub const DrawCmd = struct {
    mesh: *const Mesh,
    model: math.Mat4,
};

/// Sky/horizon color (linear) — also the fog color.
pub const sky_color = [4]f32{ 0.34, 0.57, 0.82, 1.0 };

pub const Renderer = struct {
    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    phys: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    qfam: u32 = 0,
    swapchain: c.VkSwapchainKHR = null,
    format: c.VkFormat = c.VK_FORMAT_B8G8R8A8_SRGB,
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    image_count: u32 = 0,
    images: [max_images]c.VkImage = undefined,
    views: [max_images]c.VkImageView = undefined,
    render_done: [max_images]c.VkSemaphore = undefined,
    depth_image: c.VkImage = null,
    depth_mem: c.VkDeviceMemory = null,
    depth_view: c.VkImageView = null,
    pool: c.VkCommandPool = null,
    cmd: c.VkCommandBuffer = null,
    acquire_sem: c.VkSemaphore = null,
    fence: c.VkFence = null,
    layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,
    mem_props: c.VkPhysicalDeviceMemoryProperties = undefined,
    meshes: [384]Mesh = [_]Mesh{.{}} ** 384,
    mesh_count: usize = 0,
    last_image_idx: u32 = 0,
    uncapped: bool = false,
    actual_present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR,
    gpu_name: [256]u8 = [_]u8{0} ** 256,

    pub const FrameTiming = struct {
        gpu_wait_ms: f32 = 0.0,
        acquire_ms: f32 = 0.0,
        record_ms: f32 = 0.0,
        submit_ms: f32 = 0.0,
        present_ms: f32 = 0.0,
    };
    pub var last_frame_timing: FrameTiming = .{};

    fn getMonotonicNs() u64 {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
    }

    pub fn init(self: *Renderer, win: *Window) !void {
        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "AirplaneGame",
            .apiVersion = c.VK_API_VERSION_1_3,
        };
        const exts = [_][*c]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
        const want_validation = std.c.getenv("VK_VALIDATE") != null;
        const layers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
        var ici = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = exts.len,
            .ppEnabledExtensionNames = &exts,
        };
        if (want_validation) {
            ici.enabledLayerCount = 1;
            ici.ppEnabledLayerNames = &layers;
        }
        try vk(c.vkCreateInstance(&ici, null, &self.instance));

        const sci = c.VkWaylandSurfaceCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = win.display,
            .surface = win.surface,
        };
        try vk(c.vkCreateWaylandSurfaceKHR(self.instance, &sci, null, &self.surface));

        var pd_count: u32 = 0;
        try vk(c.vkEnumeratePhysicalDevices(self.instance, &pd_count, null));
        var pds: [8]c.VkPhysicalDevice = undefined;
        pd_count = @min(pd_count, pds.len);
        try vk(c.vkEnumeratePhysicalDevices(self.instance, &pd_count, &pds));
        var found = false;
        var best_discrete = false;
        for (pds[0..pd_count]) |pd| {
            var props: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(pd, &props);
            var qn: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, null);
            var qs: [16]c.VkQueueFamilyProperties = undefined;
            qn = @min(qn, qs.len);
            c.vkGetPhysicalDeviceQueueFamilyProperties(pd, &qn, &qs);
            for (qs[0..qn], 0..) |q, i| {
                var present: c.VkBool32 = 0;
                _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(pd, @intCast(i), self.surface, &present);
                if ((q.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0 and present != 0) {
                    const discrete = props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
                    if (!found or (discrete and !best_discrete)) {
                        self.phys = pd;
                        self.qfam = @intCast(i);
                        best_discrete = discrete;
                        found = true;
                    }
                    break;
                }
            }
        }
        if (!found) return error.NoSuitableGpu;
        var props: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(self.phys, &props);
        const dev_name = std.mem.span(@as([*:0]const u8, @ptrCast(&props.deviceName)));
        const copy_l = @min(dev_name.len, self.gpu_name.len - 1);
        @memcpy(self.gpu_name[0..copy_l], dev_name[0..copy_l]);
        self.gpu_name[copy_l] = 0;
        log.info("GPU: {s}", .{self.gpu_name[0..copy_l]});
        c.vkGetPhysicalDeviceMemoryProperties(self.phys, &self.mem_props);

        const prio: f32 = 1.0;
        const qci = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.qfam,
            .queueCount = 1,
            .pQueuePriorities = &prio,
        };
        var f13 = c.VkPhysicalDeviceVulkan13Features{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .dynamicRendering = c.VK_TRUE,
            .synchronization2 = c.VK_TRUE,
        };
        const dev_exts = [_][*c]const u8{"VK_KHR_swapchain"};
        const dci = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &f13,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &qci,
            .enabledExtensionCount = dev_exts.len,
            .ppEnabledExtensionNames = &dev_exts,
        };
        try vk(c.vkCreateDevice(self.phys, &dci, null, &self.device));
        c.vkGetDeviceQueue(self.device, self.qfam, 0, &self.queue);

        const cpi = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.qfam,
        };
        try vk(c.vkCreateCommandPool(self.device, &cpi, null, &self.pool));
        const cbi = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try vk(c.vkAllocateCommandBuffers(self.device, &cbi, &self.cmd));
        const sem_info = c.VkSemaphoreCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        try vk(c.vkCreateSemaphore(self.device, &sem_info, null, &self.acquire_sem));
        const fence_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        try vk(c.vkCreateFence(self.device, &fence_info, null, &self.fence));

        try self.createPipeline();
        try self.createSwapchain(win.width, win.height);
    }

    fn findMemType(self: *Renderer, type_bits: u32, flags: c.VkMemoryPropertyFlags) !u32 {
        for (0..self.mem_props.memoryTypeCount) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            if ((type_bits & bit) != 0 and (self.mem_props.memoryTypes[i].propertyFlags & flags) == flags) return @intCast(i);
        }
        return error.NoMemoryType;
    }

    fn createHostBuffer(self: *Renderer, data: []const u8, usage: c.VkBufferUsageFlags, buf: *c.VkBuffer, mem: *c.VkDeviceMemory) !void {
        const bci = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = data.len,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };
        try vk(c.vkCreateBuffer(self.device, &bci, null, buf));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, buf.*, &req);
        const mai = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try self.findMemType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
        };
        try vk(c.vkAllocateMemory(self.device, &mai, null, mem));
        try vk(c.vkBindBufferMemory(self.device, buf.*, mem.*, 0));
        var ptr: ?*anyopaque = null;
        try vk(c.vkMapMemory(self.device, mem.*, 0, data.len, 0, &ptr));
        @memcpy(@as([*]u8, @ptrCast(ptr.?))[0..data.len], data);
        c.vkUnmapMemory(self.device, mem.*);
    }

    /// Upload a static mesh. Pointer stays valid for the renderer's lifetime.
    pub fn createMesh(self: *Renderer, verts: []const mesh_mod.Vertex, indices: []const u32) !*const Mesh {
        if (self.mesh_count >= self.meshes.len) return error.TooManyMeshes;
        const m = &self.meshes[self.mesh_count];
        try self.createHostBuffer(std.mem.sliceAsBytes(verts), c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &m.vbuf, &m.vmem);
        try self.createHostBuffer(std.mem.sliceAsBytes(indices), c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, &m.ibuf, &m.imem);
        m.index_count = @intCast(indices.len);
        self.mesh_count += 1;
        return m;
    }

    /// Update an existing mesh in-place. Waits for GPU idle, destroys old buffers and re-allocates.
    pub fn updateMesh(self: *Renderer, m_in: *const Mesh, verts: []const mesh_mod.Vertex, indices: []const u32) !void {
        _ = c.vkDeviceWaitIdle(self.device);
        const m: *Mesh = @constCast(m_in);
        if (m.vbuf != null) c.vkDestroyBuffer(self.device, m.vbuf, null);
        if (m.vmem != null) c.vkFreeMemory(self.device, m.vmem, null);
        if (m.ibuf != null) c.vkDestroyBuffer(self.device, m.ibuf, null);
        if (m.imem != null) c.vkFreeMemory(self.device, m.imem, null);
        m.vbuf = null;
        m.vmem = null;
        m.ibuf = null;
        m.imem = null;
        m.index_count = 0;
        try self.createHostBuffer(std.mem.sliceAsBytes(verts), c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &m.vbuf, &m.vmem);
        try self.createHostBuffer(std.mem.sliceAsBytes(indices), c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, &m.ibuf, &m.imem);
        m.index_count = @intCast(indices.len);
    }

    fn shaderModule(self: *Renderer, code: []align(4) const u8) !c.VkShaderModule {
        const info = c.VkShaderModuleCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = code.len,
            .pCode = @ptrCast(code.ptr),
        };
        var m: c.VkShaderModule = null;
        try vk(c.vkCreateShaderModule(self.device, &info, null, &m));
        return m;
    }

    fn createPipeline(self: *Renderer) !void {
        const vs = try self.shaderModule(&vert_spv);
        defer c.vkDestroyShaderModule(self.device, vs, null);
        const fs = try self.shaderModule(&frag_spv);
        defer c.vkDestroyShaderModule(self.device, fs, null);

        const pcr = c.VkPushConstantRange{ .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = @sizeOf(Push) };
        const plci = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &pcr,
        };
        try vk(c.vkCreatePipelineLayout(self.device, &plci, null, &self.layout));

        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" },
        };
        const binding = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(mesh_mod.Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        const attrs = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(mesh_mod.Vertex, "pos") },
            .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(mesh_mod.Vertex, "nrm") },
            .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(mesh_mod.Vertex, "col") },
        };
        const vi = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding,
            .vertexAttributeDescriptionCount = attrs.len,
            .pVertexAttributeDescriptions = &attrs,
        };
        const ia = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        };
        const vp = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        };
        const rs = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE, // flat-shaded w/ explicit normals; avoid winding bugs for now
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .lineWidth = 1.0,
        };
        const ms = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        };
        const ds = c.VkPipelineDepthStencilStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = c.VK_TRUE,
            .depthWriteEnable = c.VK_TRUE,
            .depthCompareOp = c.VK_COMPARE_OP_LESS,
        };
        const blend_att = c.VkPipelineColorBlendAttachmentState{ .colorWriteMask = 0xF };
        const cb = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &blend_att,
        };
        const dyn_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dyn = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dyn_states.len,
            .pDynamicStates = &dyn_states,
        };
        const color_fmt = [_]c.VkFormat{self.format};
        const rendering = c.VkPipelineRenderingCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &color_fmt,
            .depthAttachmentFormat = depth_format,
        };
        const gpci = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vi,
            .pInputAssemblyState = &ia,
            .pViewportState = &vp,
            .pRasterizationState = &rs,
            .pMultisampleState = &ms,
            .pDepthStencilState = &ds,
            .pColorBlendState = &cb,
            .pDynamicState = &dyn,
            .layout = self.layout,
        };
        try vk(c.vkCreateGraphicsPipelines(self.device, null, 1, &gpci, null, &self.pipeline));
    }

    fn destroySwapchain(self: *Renderer) void {
        _ = c.vkDeviceWaitIdle(self.device);
        for (0..self.image_count) |i| {
            c.vkDestroyImageView(self.device, self.views[i], null);
            c.vkDestroySemaphore(self.device, self.render_done[i], null);
        }
        self.image_count = 0;
        if (self.depth_view != null) c.vkDestroyImageView(self.device, self.depth_view, null);
        if (self.depth_image != null) c.vkDestroyImage(self.device, self.depth_image, null);
        if (self.depth_mem != null) c.vkFreeMemory(self.device, self.depth_mem, null);
        self.depth_view = null;
        self.depth_image = null;
        self.depth_mem = null;
        if (self.swapchain != null) c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
    }

    fn createDepth(self: *Renderer) !void {
        const ici = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = depth_format,
            .extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        try vk(c.vkCreateImage(self.device, &ici, null, &self.depth_image));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, self.depth_image, &req);
        const mai = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try self.findMemType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };
        try vk(c.vkAllocateMemory(self.device, &mai, null, &self.depth_mem));
        try vk(c.vkBindImageMemory(self.device, self.depth_image, self.depth_mem, 0));
        const ivi = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = self.depth_image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = depth_format,
            .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 },
        };
        try vk(c.vkCreateImageView(self.device, &ivi, null, &self.depth_view));
    }

    fn createSwapchain(self: *Renderer, w: u32, h: u32) !void {
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try vk(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.phys, self.surface, &caps));
        self.extent = if (caps.currentExtent.width != 0xFFFFFFFF)
            caps.currentExtent
        else
            .{
                .width = std.math.clamp(w, caps.minImageExtent.width, caps.maxImageExtent.width),
                .height = std.math.clamp(h, caps.minImageExtent.height, caps.maxImageExtent.height),
            };

        var fmt_n: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.phys, self.surface, &fmt_n, null);
        var fmts: [32]c.VkSurfaceFormatKHR = undefined;
        fmt_n = @min(fmt_n, fmts.len);
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.phys, self.surface, &fmt_n, &fmts);
        var chosen = fmts[0];
        for (fmts[0..fmt_n]) |f| {
            if (f.format == self.format and f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) chosen = f;
        }
        std.debug.assert(chosen.format == self.format);

        var want: u32 = caps.minImageCount + 1;
        if (caps.maxImageCount > 0) want = @min(want, caps.maxImageCount);
        want = @min(want, max_images);

        var chosen_present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR;
        if (self.uncapped) {
            var mode_n: u32 = 0;
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(self.phys, self.surface, &mode_n, null);
            var modes: [16]c.VkPresentModeKHR = undefined;
            mode_n = @min(mode_n, modes.len);
            _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(self.phys, self.surface, &mode_n, &modes);
            for (modes[0..mode_n]) |m| {
                if (m == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                    chosen_present_mode = c.VK_PRESENT_MODE_MAILBOX_KHR;
                    break;
                } else if (m == c.VK_PRESENT_MODE_IMMEDIATE_KHR and chosen_present_mode != c.VK_PRESENT_MODE_MAILBOX_KHR) {
                    chosen_present_mode = c.VK_PRESENT_MODE_IMMEDIATE_KHR;
                }
            }
        }
        self.actual_present_mode = chosen_present_mode;

        const sci = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = want,
            .imageFormat = chosen.format,
            .imageColorSpace = chosen.colorSpace,
            .imageExtent = self.extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = chosen_present_mode,
            .clipped = c.VK_TRUE,
        };
        try vk(c.vkCreateSwapchainKHR(self.device, &sci, null, &self.swapchain));
        self.image_count = max_images;
        try vk(c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &self.image_count, &self.images));
        for (0..self.image_count) |i| {
            const ivi = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = self.images[i],
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.format,
                .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 },
            };
            try vk(c.vkCreateImageView(self.device, &ivi, null, &self.views[i]));
            const sem_info = c.VkSemaphoreCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
            try vk(c.vkCreateSemaphore(self.device, &sem_info, null, &self.render_done[i]));
        }
        try self.createDepth();
    }

    pub fn recreate(self: *Renderer, w: u32, h: u32) !void {
        self.destroySwapchain();
        try self.createSwapchain(w, h);
    }

    pub fn aspect(self: *const Renderer) f32 {
        return @as(f32, @floatFromInt(self.extent.width)) / @as(f32, @floatFromInt(@max(self.extent.height, 1)));
    }

    fn barrier(self: *Renderer, image: c.VkImage, aspect_mask: c.VkImageAspectFlags, old: c.VkImageLayout, new: c.VkImageLayout, src_stage: u64, dst_stage: u64, src_acc: u64, dst_acc: u64) void {
        const b = c.VkImageMemoryBarrier2{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .srcStageMask = src_stage,
            .srcAccessMask = src_acc,
            .dstStageMask = dst_stage,
            .dstAccessMask = dst_acc,
            .oldLayout = old,
            .newLayout = new,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{ .aspectMask = aspect_mask, .levelCount = 1, .layerCount = 1 },
        };
        const dep = c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &b,
        };
        c.vkCmdPipelineBarrier2(self.cmd, &dep);
    }

    /// Returns false if the swapchain must be recreated.
    pub fn drawFrame(self: *Renderer, view_proj: math.Mat4, draws: []const DrawCmd, ui_start_idx: usize, clear_color: [4]f32, sun_angle: f32) !bool {
        const t0 = getMonotonicNs();
        try vk(c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)));
        const t1 = getMonotonicNs();
        var idx: u32 = 0;
        const acq = c.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.acquire_sem, null, &idx);
        if (acq == c.VK_ERROR_OUT_OF_DATE_KHR) return false;
        if (acq != c.VK_SUCCESS and acq != c.VK_SUBOPTIMAL_KHR) return error.VulkanFailed;
        try vk(c.vkResetFences(self.device, 1, &self.fence));
        const t2 = getMonotonicNs();

        try vk(c.vkResetCommandBuffer(self.cmd, 0));
        const bi = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try vk(c.vkBeginCommandBuffer(self.cmd, &bi));

        self.barrier(self.images[idx], c.VK_IMAGE_ASPECT_COLOR_BIT, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, 0, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
        const depth_stages = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
        self.barrier(self.depth_image, c.VK_IMAGE_ASPECT_DEPTH_BIT, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL, depth_stages, depth_stages, 0, c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT);

        const color_att = c.VkRenderingAttachmentInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = self.views[idx],
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = .{ .color = .{ .float32 = clear_color } },
        };
        const depth_att = c.VkRenderingAttachmentInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = self.depth_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        const ri = c.VkRenderingInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_att,
            .pDepthAttachment = &depth_att,
        };
        c.vkCmdBeginRendering(self.cmd, &ri);
        c.vkCmdBindPipeline(self.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(self.extent.width), .height = @floatFromInt(self.extent.height), .minDepth = 0, .maxDepth = 1 };
        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        c.vkCmdSetViewport(self.cmd, 0, 1, &viewport);
        c.vkCmdSetScissor(self.cmd, 0, 1, &scissor);

        var bound: ?*const Mesh = null;
        for (draws, 0..) |d, i| {
            if (i == ui_start_idx) {
                const clear_att = c.VkClearAttachment{
                    .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
                    .colorAttachment = 0,
                    .clearValue = .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
                };
                const clear_rect = c.VkClearRect{
                    .rect = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                };
                c.vkCmdClearAttachments(self.cmd, 1, &clear_att, 1, &clear_rect);
            }
            if (bound != d.mesh) {
                const offset: c.VkDeviceSize = 0;
                c.vkCmdBindVertexBuffers(self.cmd, 0, 1, &d.mesh.vbuf, &offset);
                c.vkCmdBindIndexBuffer(self.cmd, d.mesh.ibuf, 0, c.VK_INDEX_TYPE_UINT32);
                bound = d.mesh;
            }
            var push = Push{ .view_proj = view_proj.m, .model = d.model.m };
            push.model[15] = sun_angle;
            c.vkCmdPushConstants(self.cmd, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Push), &push);
            c.vkCmdDrawIndexed(self.cmd, d.mesh.index_count, 1, 0, 0, 0);
        }
        c.vkCmdEndRendering(self.cmd);

        self.barrier(self.images[idx], c.VK_IMAGE_ASPECT_COLOR_BIT, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, 0);
        try vk(c.vkEndCommandBuffer(self.cmd));
        const t3 = getMonotonicNs();

        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        const si = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.acquire_sem,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.render_done[idx],
        };
        try vk(c.vkQueueSubmit(self.queue, 1, &si, self.fence));
        const t4 = getMonotonicNs();

        const pi = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_done[idx],
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &idx,
        };
        const pr = c.vkQueuePresentKHR(self.queue, &pi);
        const t5 = getMonotonicNs();

        last_frame_timing = .{
            .gpu_wait_ms = @as(f32, @floatFromInt(t1 - t0)) * 1e-6,
            .acquire_ms = @as(f32, @floatFromInt(t2 - t1)) * 1e-6,
            .record_ms = @as(f32, @floatFromInt(t3 - t2)) * 1e-6,
            .submit_ms = @as(f32, @floatFromInt(t4 - t3)) * 1e-6,
            .present_ms = @as(f32, @floatFromInt(t5 - t4)) * 1e-6,
        };

        self.last_image_idx = idx;
        if (pr == c.VK_ERROR_OUT_OF_DATE_KHR or pr == c.VK_SUBOPTIMAL_KHR) return false;
        if (pr != c.VK_SUCCESS) return error.VulkanFailed;
        return true;
    }

    /// Captures the most recently presented swapchain image to a binary PPM (`P6`) file.
    pub fn saveScreenshotPPM(self: *Renderer, path: [*:0]const u8) !void {
        _ = c.vkDeviceWaitIdle(self.device);
        const w = self.extent.width;
        const h = self.extent.height;
        const byte_len: usize = @as(usize, w) * @as(usize, h) * 4;

        var buf: c.VkBuffer = null;
        var mem: c.VkDeviceMemory = null;
        const bci = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = byte_len,
            .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };
        try vk(c.vkCreateBuffer(self.device, &bci, null, &buf));
        defer c.vkDestroyBuffer(self.device, buf, null);

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, buf, &req);
        const mai = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try self.findMemType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
        };
        try vk(c.vkAllocateMemory(self.device, &mai, null, &mem));
        defer c.vkFreeMemory(self.device, mem, null);
        try vk(c.vkBindBufferMemory(self.device, buf, mem, 0));

        try vk(c.vkResetCommandBuffer(self.cmd, 0));
        const bi = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try vk(c.vkBeginCommandBuffer(self.cmd, &bi));
        const img = self.images[self.last_image_idx];
        self.barrier(img, c.VK_IMAGE_ASPECT_COLOR_BIT, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, c.VK_PIPELINE_STAGE_2_TRANSFER_BIT, 0, c.VK_ACCESS_2_TRANSFER_READ_BIT);

        const region = c.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = w, .height = h, .depth = 1 },
        };
        c.vkCmdCopyImageToBuffer(self.cmd, img, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &region);
        self.barrier(img, c.VK_IMAGE_ASPECT_COLOR_BIT, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_PIPELINE_STAGE_2_TRANSFER_BIT, c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT, c.VK_ACCESS_2_TRANSFER_READ_BIT, 0);
        try vk(c.vkEndCommandBuffer(self.cmd));

        const si = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cmd,
        };
        try vk(c.vkQueueSubmit(self.queue, 1, &si, null));
        _ = c.vkQueueWaitIdle(self.queue);

        var ptr: ?*anyopaque = null;
        try vk(c.vkMapMemory(self.device, mem, 0, byte_len, 0, &ptr));
        defer c.vkUnmapMemory(self.device, mem);
        const bgra: [*]const u8 = @ptrCast(ptr.?);

        const fp = c.fopen(path, "wb") orelse return error.FileOpenFailed;
        defer _ = c.fclose(fp);
        var hdr_buf: [64]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&hdr_buf, "P6\n{d} {d}\n255\n", .{ w, h });
        _ = c.fwrite(hdr.ptr, 1, hdr.len, fp);

        var row_rgb: [4096 * 3]u8 = undefined;
        const row_w = @min(@as(usize, w), 4096);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < row_w) : (x += 1) {
                const p = (y * @as(usize, w) + x) * 4;
                row_rgb[x * 3 + 0] = bgra[p + 2]; // R
                row_rgb[x * 3 + 1] = bgra[p + 1]; // G
                row_rgb[x * 3 + 2] = bgra[p + 0]; // B
            }
            _ = c.fwrite(&row_rgb, 1, row_w * 3, fp);
        }
        log.info("saved screenshot: {s} ({d}x{d})", .{ path, w, h });
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device == null) return;
        _ = c.vkDeviceWaitIdle(self.device);
        self.destroySwapchain();
        for (self.meshes[0..self.mesh_count]) |m| {
            c.vkDestroyBuffer(self.device, m.vbuf, null);
            c.vkFreeMemory(self.device, m.vmem, null);
            c.vkDestroyBuffer(self.device, m.ibuf, null);
            c.vkFreeMemory(self.device, m.imem, null);
        }
        c.vkDestroyPipeline(self.device, self.pipeline, null);
        c.vkDestroyPipelineLayout(self.device, self.layout, null);
        c.vkDestroyFence(self.device, self.fence, null);
        c.vkDestroySemaphore(self.device, self.acquire_sem, null);
        c.vkDestroyCommandPool(self.device, self.pool, null);
        c.vkDestroyDevice(self.device, null);
        c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        c.vkDestroyInstance(self.instance, null);
    }
};
