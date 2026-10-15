//! Phase 1: raw Wayland window + Vulkan 1.3 (dynamic rendering) triangle.
const std = @import("std");
const c = @import("c");

const vert_spv align(4) = @embedFile("tri.vert.spv").*;
const frag_spv align(4) = @embedFile("tri.frag.spv").*;

const log = std.log.scoped(.game);

fn vk(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) {
        log.err("Vulkan error: {d}", .{result});
        return error.VulkanFailed;
    }
}

// ───────────────────────── Wayland ─────────────────────────

const Window = struct {
    display: *c.struct_wl_display_1 = undefined,
    registry: *c.struct_wl_registry = undefined,
    compositor: ?*c.struct_wl_compositor = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    surface: *c.struct_wl_surface_2 = undefined,
    xdg_surface: *c.struct_xdg_surface = undefined,
    toplevel: *c.struct_xdg_toplevel = undefined,
    width: u32 = 1280,
    height: u32 = 720,
    configured: bool = false,
    should_close: bool = false,
    resized: bool = false,

    const registry_listener: c.struct_wl_registry_listener = .{
        .global = onGlobal,
        .global_remove = onGlobalRemove,
    };
    const wm_listener: c.struct_xdg_wm_base_listener = .{ .ping = onPing };
    const xdg_surface_listener: c.struct_xdg_surface_listener = .{ .configure = onSurfaceConfigure };
    const toplevel_listener: c.struct_xdg_toplevel_listener = .{
        .configure = onToplevelConfigure,
        .close = onToplevelClose,
        .configure_bounds = onConfigureBounds,
        .wm_capabilities = onWmCapabilities,
    };

    fn init(self: *Window) !void {
        self.display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        self.registry = c.wl_display_get_registry(self.display) orelse return error.NoRegistry;
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        _ = c.wl_display_roundtrip(self.display);
        const comp = self.compositor orelse return error.NoCompositor;
        const wm = self.wm_base orelse return error.NoXdgShell;
        _ = c.xdg_wm_base_add_listener(wm, &wm_listener, self);

        self.surface = c.wl_compositor_create_surface(comp) orelse return error.NoSurface;
        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(wm, self.surface) orelse return error.NoSurface;
        _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);
        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse return error.NoSurface;
        _ = c.xdg_toplevel_add_listener(self.toplevel, &toplevel_listener, self);
        c.xdg_toplevel_set_title(self.toplevel, "Airplane Game");
        c.xdg_toplevel_set_app_id(self.toplevel, "airplane_game");
        c.wl_surface_commit(self.surface);
        while (!self.configured) {
            if (c.wl_display_dispatch(self.display) < 0) return error.WaylandDispatch;
        }
    }

    /// Non-blocking event pump.
    fn pump(self: *Window) void {
        while (c.wl_display_prepare_read(self.display) != 0) {
            _ = c.wl_display_dispatch_pending(self.display);
        }
        _ = c.wl_display_flush(self.display);
        var pfd = c.struct_pollfd{ .fd = c.wl_display_get_fd(self.display), .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 0) > 0) {
            _ = c.wl_display_read_events(self.display);
        } else {
            c.wl_display_cancel_read(self.display);
        }
        _ = c.wl_display_dispatch_pending(self.display);
    }

    fn onGlobal(data: ?*anyopaque, reg: ?*c.struct_wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        const i = std.mem.span(iface);
        if (std.mem.eql(u8, i, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, i, "xdg_wm_base")) {
            self.wm_base = @ptrCast(c.wl_registry_bind(reg, name, &c.xdg_wm_base_interface, 1));
        }
    }
    fn onGlobalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}
    fn onPing(_: ?*anyopaque, wm: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
        c.xdg_wm_base_pong(wm, serial);
    }
    fn onSurfaceConfigure(data: ?*anyopaque, s: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        c.xdg_surface_ack_configure(s, serial);
        self.configured = true;
    }
    fn onToplevelConfigure(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel, w: i32, h: i32, _: [*c]c.struct_wl_array) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        if (w > 0 and h > 0 and (self.width != w or self.height != h)) {
            self.width = @intCast(w);
            self.height = @intCast(h);
            self.resized = true;
        }
    }
    fn onToplevelClose(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data));
        self.should_close = true;
    }
    fn onConfigureBounds(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
    fn onWmCapabilities(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: [*c]c.struct_wl_array) callconv(.c) void {}
};

// ───────────────────────── Vulkan ─────────────────────────

const max_images = 8;

const Renderer = struct {
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
    pool: c.VkCommandPool = null,
    cmd: c.VkCommandBuffer = null,
    acquire_sem: c.VkSemaphore = null,
    fence: c.VkFence = null,
    layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    fn init(self: *Renderer, win: *Window) !void {
        // Instance
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

        // Surface
        const sci = c.VkWaylandSurfaceCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = win.display,
            .surface = win.surface,
        };
        try vk(c.vkCreateWaylandSurfaceKHR(self.instance, &sci, null, &self.surface));

        // Physical device + queue family (graphics + present)
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
        log.info("GPU: {s}", .{@as([*:0]const u8, @ptrCast(&props.deviceName))});

        // Logical device (1.3: dynamic rendering + sync2)
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

        // Command pool / buffer / sync
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

        const plci = c.VkPipelineLayoutCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
        try vk(c.vkCreatePipelineLayout(self.device, &plci, null, &self.layout));

        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" },
        };
        const vi = c.VkPipelineVertexInputStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
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
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
            .lineWidth = 1.0,
        };
        const ms = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
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
        if (self.swapchain != null) c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
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
        std.debug.assert(chosen.format == self.format); // pipeline was built for this format

        var want: u32 = caps.minImageCount + 1;
        if (caps.maxImageCount > 0) want = @min(want, caps.maxImageCount);
        want = @min(want, max_images);
        const sci = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = want,
            .imageFormat = chosen.format,
            .imageColorSpace = chosen.colorSpace,
            .imageExtent = self.extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
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
    }

    fn recreate(self: *Renderer, w: u32, h: u32) !void {
        self.destroySwapchain();
        try self.createSwapchain(w, h);
    }

    fn barrier(self: *Renderer, image: c.VkImage, old: c.VkImageLayout, new: c.VkImageLayout, src_stage: u64, dst_stage: u64, src_acc: u64, dst_acc: u64) void {
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
            .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 },
        };
        const dep = c.VkDependencyInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &b,
        };
        c.vkCmdPipelineBarrier2(self.cmd, &dep);
    }

    /// Returns false if the swapchain must be recreated.
    fn drawFrame(self: *Renderer, time: f32) !bool {
        try vk(c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)));
        var idx: u32 = 0;
        const acq = c.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.acquire_sem, null, &idx);
        if (acq == c.VK_ERROR_OUT_OF_DATE_KHR) return false;
        if (acq != c.VK_SUCCESS and acq != c.VK_SUBOPTIMAL_KHR) return error.VulkanFailed;
        try vk(c.vkResetFences(self.device, 1, &self.fence));

        try vk(c.vkResetCommandBuffer(self.cmd, 0));
        const bi = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try vk(c.vkBeginCommandBuffer(self.cmd, &bi));

        self.barrier(self.images[idx], c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, 0, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);

        // Sky-ish background that gently breathes, to prove frames are live.
        const pulse = 0.5 + 0.5 * @sin(time);
        const clear = c.VkClearValue{ .color = .{ .float32 = .{ 0.02 + 0.03 * pulse, 0.08 + 0.06 * pulse, 0.18 + 0.1 * pulse, 1.0 } } };
        const color_att = c.VkRenderingAttachmentInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = self.views[idx],
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = clear,
        };
        const ri = c.VkRenderingInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_att,
        };
        c.vkCmdBeginRendering(self.cmd, &ri);
        c.vkCmdBindPipeline(self.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(self.extent.width), .height = @floatFromInt(self.extent.height), .minDepth = 0, .maxDepth = 1 };
        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        c.vkCmdSetViewport(self.cmd, 0, 1, &viewport);
        c.vkCmdSetScissor(self.cmd, 0, 1, &scissor);
        c.vkCmdDraw(self.cmd, 3, 1, 0, 0);
        c.vkCmdEndRendering(self.cmd);

        self.barrier(self.images[idx], c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, 0);
        try vk(c.vkEndCommandBuffer(self.cmd));

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

        const pi = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_done[idx],
            .swapchainCount = 1,
            .pSwapchains = &self.swapchain,
            .pImageIndices = &idx,
        };
        const pr = c.vkQueuePresentKHR(self.queue, &pi);
        if (pr == c.VK_ERROR_OUT_OF_DATE_KHR or pr == c.VK_SUBOPTIMAL_KHR) return false;
        if (pr != c.VK_SUCCESS) return error.VulkanFailed;
        return true;
    }

    fn deinit(self: *Renderer) void {
        if (self.device == null) return;
        _ = c.vkDeviceWaitIdle(self.device);
        self.destroySwapchain();
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

pub fn main() !void {
    var win = Window{};
    try win.init();
    var r = Renderer{};
    defer r.deinit();
    try r.init(&win);

    // Optional: AG_FRAMES=N exits after N frames (for automated smoke tests).
    const max_frames: u64 = if (std.c.getenv("AG_FRAMES")) |s|
        std.fmt.parseInt(u64, std.mem.span(s), 10) catch 0
    else
        0;

    var frame: u64 = 0;
    while (!win.should_close) {
        win.pump();
        if (win.resized) {
            win.resized = false;
            try r.recreate(win.width, win.height);
        }
        const t: f32 = @as(f32, @floatFromInt(frame)) / 60.0;
        if (!try r.drawFrame(t)) try r.recreate(win.width, win.height);
        frame += 1;
        if (max_frames != 0 and frame >= max_frames) break;
    }
    log.info("exited cleanly after {d} frames", .{frame});
}
