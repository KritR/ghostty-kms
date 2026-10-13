//! Puts the renderer's frames on screen.
//!
//! Ghostty's OpenGL renderer draws into an offscreen texture and exports
//! each finished frame as a DMABUF (or, if that fails, as CPU pixels). We
//! own a small GLES 2 context on a GBM surface for the scanout device. For
//! each frame we import the DMABUF as an EGLImage-backed texture (or upload
//! the pixels), draw it as a fullscreen quad, swap, lock the GBM front
//! buffer, wrap it in a DRM framebuffer and page-flip to it.
//!
//! Blitting instead of scanning out the renderer's buffer directly means
//! we never have to care whether its format/modifier is scanout-capable,
//! and it lets us fix the orientation: GL's origin is bottom-left.
const Presenter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("kms_c");
const gl = @import("opengl");
const egl = gl.egl;
const Drm = @import("Drm.zig");
const util = @import("util.zig");
const rendererpkg = @import("../../renderer.zig");
const ExportedFrame = rendererpkg.Renderer.ExportedFrame;
const Dmabuf = @import("../../renderer/Dmabuf.zig");

const log = std.log.scoped(.kms_presenter);

// EGL extension tokens. Ghostty's glad EGL header only covers EGL 1.5
// core plus two Mesa extensions, so we define what we use here.
const EGL_PLATFORM_GBM_KHR = 0x31D7;
const EGL_LINUX_DMA_BUF_EXT = 0x3270;
const EGL_LINUX_DRM_FOURCC_EXT = 0x3271;
const EGL_DMA_BUF_PLANE0_FD_EXT = 0x3272;
const EGL_DMA_BUF_PLANE0_OFFSET_EXT = 0x3273;
const EGL_DMA_BUF_PLANE0_PITCH_EXT = 0x3274;
const EGL_DMA_BUF_PLANE1_FD_EXT = 0x3275;
const EGL_DMA_BUF_PLANE1_OFFSET_EXT = 0x3276;
const EGL_DMA_BUF_PLANE1_PITCH_EXT = 0x3277;
const EGL_DMA_BUF_PLANE2_FD_EXT = 0x3278;
const EGL_DMA_BUF_PLANE2_OFFSET_EXT = 0x3279;
const EGL_DMA_BUF_PLANE2_PITCH_EXT = 0x327A;
const EGL_DMA_BUF_PLANE3_FD_EXT = 0x3440;
const EGL_DMA_BUF_PLANE3_OFFSET_EXT = 0x3441;
const EGL_DMA_BUF_PLANE3_PITCH_EXT = 0x3442;
const EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT = 0x3443;
const EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT = 0x3444;
const EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT = 0x3445;
const EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT = 0x3446;
const EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT = 0x3447;
const EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT = 0x3448;
const EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT = 0x3449;
const EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT = 0x344A;

const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;

fn fourcc(comptime s: *const [4]u8) u32 {
    return @as(u32, s[0]) | (@as(u32, s[1]) << 8) | (@as(u32, s[2]) << 16) | (@as(u32, s[3]) << 24);
}
const DRM_FORMAT_XRGB8888 = fourcc("XR24");
const DRM_FORMAT_ARGB8888 = fourcc("AR24");

const PlaneAttrs = struct { fd: c_int, offset: c_int, pitch: c_int, mod_lo: c_int, mod_hi: c_int };
const plane_attrs = [Dmabuf.max_planes]PlaneAttrs{
    .{ .fd = EGL_DMA_BUF_PLANE0_FD_EXT, .offset = EGL_DMA_BUF_PLANE0_OFFSET_EXT, .pitch = EGL_DMA_BUF_PLANE0_PITCH_EXT, .mod_lo = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, .mod_hi = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT },
    .{ .fd = EGL_DMA_BUF_PLANE1_FD_EXT, .offset = EGL_DMA_BUF_PLANE1_OFFSET_EXT, .pitch = EGL_DMA_BUF_PLANE1_PITCH_EXT, .mod_lo = EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT, .mod_hi = EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT },
    .{ .fd = EGL_DMA_BUF_PLANE2_FD_EXT, .offset = EGL_DMA_BUF_PLANE2_OFFSET_EXT, .pitch = EGL_DMA_BUF_PLANE2_PITCH_EXT, .mod_lo = EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, .mod_hi = EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT },
    .{ .fd = EGL_DMA_BUF_PLANE3_FD_EXT, .offset = EGL_DMA_BUF_PLANE3_OFFSET_EXT, .pitch = EGL_DMA_BUF_PLANE3_PITCH_EXT, .mod_lo = EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT, .mod_hi = EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT },
};

const vertex_src =
    \\attribute vec2 pos;
    \\varying vec2 uv;
    \\uniform float flip_y;
    \\void main() {
    \\    uv = pos * 0.5 + 0.5;
    \\    if (flip_y > 0.5) uv.y = 1.0 - uv.y;
    \\    gl_Position = vec4(pos, 0.0, 1.0);
    \\}
;

const fragment_2d_src =
    \\#ifdef GL_FRAGMENT_PRECISION_HIGH
    \\precision highp float;
    \\#else
    \\precision mediump float;
    \\#endif
    \\varying vec2 uv;
    \\uniform sampler2D tex;
    \\void main() {
    \\    gl_FragColor = vec4(texture2D(tex, uv).rgb, 1.0);
    \\}
;

const fragment_ext_src =
    \\#extension GL_OES_EGL_image_external : require
    \\#ifdef GL_FRAGMENT_PRECISION_HIGH
    \\precision highp float;
    \\#else
    \\precision mediump float;
    \\#endif
    \\varying vec2 uv;
    \\uniform samplerExternalOES tex;
    \\void main() {
    \\    gl_FragColor = vec4(texture2D(tex, uv).rgb, 1.0);
    \\}
;

const Program = struct {
    id: c.GLuint,
    flip_y: c.GLint,
    tex: c.GLint,
};

/// Which texture currently holds the frame on screen.
const Source = enum { none, tex_2d, tex_ext };

alloc: Allocator,
drm: *Drm,

display: *egl.Display,
config: egl.c.EGLConfig,
context: egl.c.EGLContext,
gbm_surface: *c.struct_gbm_surface,
egl_surface: egl.c.EGLSurface,

image_target_texture: c.PFNGLEGLIMAGETARGETTEXTURE2DOESPROC,

program_2d: Program,
program_ext: ?Program,
vbo: c.GLuint,

/// Texture for imported DMABUFs bound as GL_TEXTURE_2D and for
/// CPU-uploaded frames.
tex_2d: c.GLuint,
/// Texture for DMABUFs that the driver only imports as external images.
tex_ext: c.GLuint,

/// The EGLImage backing the current DMABUF texture.
image: egl.c.EGLImage = null,
source: Source = .none,

/// Size of the last CPU frame uploaded into tex_2d, to reuse storage.
upload_w: u32 = 0,
upload_h: u32 = 0,

/// Flip the frame vertically when drawing. GL's window coordinates and
/// texture coordinates share a bottom-left origin, so a straight draw is
/// already upright; this exists as a knob (GHOSTTY_KMS_FLIP_Y) for drivers
/// that disagree.
flip_y: bool,

/// The buffer currently being scanned out and the one queued by a pending
/// page flip. Both are locked GBM front buffers.
front_bo: ?*c.struct_gbm_bo = null,
pending_bo: ?*c.struct_gbm_bo = null,

/// True between drmModePageFlip and its completion event.
flip_pending: bool = false,

/// A full modeset (drmModeSetCrtc) is needed before the next flip: on
/// first present and after regaining the seat.
needs_modeset: bool = true,

/// Number of frames presented, for logging.
frame_count: u64 = 0,

pub fn init(self: *Presenter, alloc: Allocator, drm: *Drm) !void {
    try egl.load();

    const display = egl.Display.initPlatform(
        EGL_PLATFORM_GBM_KHR,
        @ptrCast(drm.gbm),
        null,
    ) catch |err| {
        log.err("failed to create EGL display on GBM err={}", .{err});
        return err;
    };
    errdefer display.terminate();

    log.info("EGL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
    const exts = display.queryString(.extensions) orelse "";
    if (!egl.hasExtension(exts, "EGL_EXT_image_dma_buf_import")) {
        log.warn("EGL_EXT_image_dma_buf_import missing; frames will be presented via CPU copies", .{});
    }

    const format, const config = try chooseConfig(alloc, display);

    try egl.bindApi(egl.c.EGL_OPENGL_ES_API);
    const ctx_attrs = [_]egl.c.EGLint{ egl.c.EGL_CONTEXT_CLIENT_VERSION, 2, egl.c.EGL_NONE };
    const context = egl.c.eglCreateContext(display, config, null, &ctx_attrs);
    if (context == null) {
        log.err("failed to create GLES context", .{});
        return egl.mustError();
    }
    errdefer _ = egl.c.eglDestroyContext(display, context);

    const gbm_surface = c.gbm_surface_create(
        drm.gbm,
        drm.width(),
        drm.height(),
        format,
        c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING,
    ) orelse {
        log.err("failed to create GBM surface errno={}", .{util.errno()});
        return error.GbmSurfaceFailed;
    };
    errdefer c.gbm_surface_destroy(gbm_surface);

    const egl_surface = egl.c.eglCreatePlatformWindowSurface(display, config, gbm_surface, null);
    if (egl_surface == null) {
        log.err("failed to create EGL window surface", .{});
        return egl.mustError();
    }
    errdefer _ = egl.c.eglDestroySurface(display, egl_surface);

    self.* = .{
        .alloc = alloc,
        .drm = drm,
        .display = display,
        .config = config,
        .context = context,
        .gbm_surface = gbm_surface,
        .egl_surface = egl_surface,
        .image_target_texture = null,
        .program_2d = undefined,
        .program_ext = null,
        .vbo = 0,
        .tex_2d = 0,
        .tex_ext = 0,
        .flip_y = util.envBool("GHOSTTY_KMS_FLIP_Y"),
    };

    try self.makeCurrent();
    try self.initGl();
}

pub fn deinit(self: *Presenter) void {
    self.makeCurrent() catch {};
    if (self.image != null) _ = egl.c.eglDestroyImage(self.display, self.image);
    c.glDeleteTextures(1, &self.tex_2d);
    c.glDeleteTextures(1, &self.tex_ext);
    c.glDeleteBuffers(1, &self.vbo);
    c.glDeleteProgram(self.program_2d.id);
    if (self.program_ext) |p| c.glDeleteProgram(p.id);
    self.display.releaseCurrent();

    if (self.pending_bo) |bo| c.gbm_surface_release_buffer(self.gbm_surface, bo);
    if (self.front_bo) |bo| c.gbm_surface_release_buffer(self.gbm_surface, bo);
    _ = egl.c.eglDestroySurface(self.display, self.egl_surface);
    c.gbm_surface_destroy(self.gbm_surface);
    _ = egl.c.eglDestroyContext(self.display, self.context);
    // The EGL display is shared with the renderer; App terminates it last.
}

/// The EGL display, which the renderer also uses so that it renders on
/// the scanout GPU and its DMABUFs import without copies.
pub fn eglDisplay(self: *const Presenter) *egl.Display {
    return self.display;
}

fn makeCurrent(self: *Presenter) !void {
    // eglBindAPI is per-thread state and the renderer's init (on this
    // thread) binds desktop GL, so always rebind GLES first.
    try egl.bindApi(egl.c.EGL_OPENGL_ES_API);
    try self.display.makeCurrent(@ptrCast(self.egl_surface), @ptrCast(self.egl_surface), @ptrCast(self.context));
}

/// Pick an EGL config whose native visual matches a scanout format.
fn chooseConfig(alloc: Allocator, display: *egl.Display) !struct { u32, egl.c.EGLConfig } {
    const attrs = [_]egl.c.EGLint{
        egl.c.EGL_SURFACE_TYPE,    egl.c.EGL_WINDOW_BIT,
        egl.c.EGL_RED_SIZE,        8,
        egl.c.EGL_GREEN_SIZE,      8,
        egl.c.EGL_BLUE_SIZE,       8,
        egl.c.EGL_RENDERABLE_TYPE, egl.c.EGL_OPENGL_ES2_BIT,
        egl.c.EGL_NONE,
    };

    var n: egl.c.EGLint = 0;
    if (egl.c.eglChooseConfig(display, &attrs, null, 0, &n) != egl.c.EGL_TRUE or n == 0) {
        log.err("no EGL configs for GLES on GBM", .{});
        return error.NoEglConfig;
    }
    const configs = try alloc.alloc(egl.c.EGLConfig, @intCast(n));
    defer alloc.free(configs);
    if (egl.c.eglChooseConfig(display, &attrs, configs.ptr, n, &n) != egl.c.EGL_TRUE) {
        return egl.mustError();
    }

    // XRGB first: scanout ignores alpha anyway and some planes don't
    // accept ARGB.
    for ([_]u32{ DRM_FORMAT_XRGB8888, DRM_FORMAT_ARGB8888 }) |want| {
        for (configs[0..@intCast(n)]) |cfg| {
            var id: egl.c.EGLint = 0;
            if (egl.c.eglGetConfigAttrib(display, cfg, egl.c.EGL_NATIVE_VISUAL_ID, &id) != egl.c.EGL_TRUE) continue;
            if (@as(u32, @bitCast(id)) == want) return .{ want, cfg };
        }
    }

    log.err("no EGL config matches a GBM scanout format", .{});
    return error.NoEglConfig;
}

fn initGl(self: *Presenter) !void {
    log.info("presenter GL_RENDERER={s} GL_VERSION={s}", .{
        glString(c.GL_RENDERER),
        glString(c.GL_VERSION),
    });

    const gl_exts = glString(c.GL_EXTENSIONS);
    if (egl.hasExtension(gl_exts, "GL_OES_EGL_image")) {
        self.image_target_texture = @ptrCast(egl.c.eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    }
    if (self.image_target_texture == null) {
        log.warn("GL_OES_EGL_image missing; frames will be presented via CPU copies", .{});
    }

    self.program_2d = try buildProgram(fragment_2d_src);
    if (egl.hasExtension(gl_exts, "GL_OES_EGL_image_external")) {
        self.program_ext = buildProgram(fragment_ext_src) catch |err| ext: {
            log.warn("external image shader failed err={}", .{err});
            break :ext null;
        };
    }

    // A fullscreen triangle strip in clip space.
    const verts = [_]f32{ -1, -1, 1, -1, -1, 1, 1, 1 };
    c.glGenBuffers(1, &self.vbo);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, c.GL_STATIC_DRAW);

    c.glGenTextures(1, &self.tex_2d);
    setupTexture(c.GL_TEXTURE_2D, self.tex_2d);
    c.glGenTextures(1, &self.tex_ext);
    if (self.program_ext != null) setupTexture(c.GL_TEXTURE_EXTERNAL_OES, self.tex_ext);

    c.glDisable(c.GL_BLEND);
    c.glDisable(c.GL_DEPTH_TEST);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
    try glCheck("init");
}

fn setupTexture(target: c.GLenum, tex: c.GLuint) void {
    c.glBindTexture(target, tex);
    c.glTexParameteri(target, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(target, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(target, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(target, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glBindTexture(target, 0);
}

fn glString(name: c.GLenum) [:0]const u8 {
    const s = c.glGetString(name) orelse return "(null)";
    return std.mem.span(@as([*:0]const u8, @ptrCast(s)));
}

fn glCheck(what: []const u8) !void {
    var failed = false;
    while (true) {
        const err = c.glGetError();
        if (err == c.GL_NO_ERROR) break;
        log.warn("GL error during {s}: 0x{x}", .{ what, err });
        failed = true;
    }
    if (failed) return error.GlError;
}

fn compileShader(kind: c.GLenum, src: [:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(kind);
    const ptr: [*c]const u8 = src.ptr;
    c.glShaderSource(shader, 1, &ptr, null);
    c.glCompileShader(shader);
    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var buf: [1024]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, buf.len, &len, &buf);
        log.err("shader compile failed: {s}", .{buf[0..@intCast(len)]});
        c.glDeleteShader(shader);
        return error.ShaderCompileFailed;
    }
    return shader;
}

fn buildProgram(fragment_src: [:0]const u8) !Program {
    const vs = try compileShader(c.GL_VERTEX_SHADER, vertex_src);
    defer c.glDeleteShader(vs);
    const fs = try compileShader(c.GL_FRAGMENT_SHADER, fragment_src);
    defer c.glDeleteShader(fs);

    const prog = c.glCreateProgram();
    c.glAttachShader(prog, vs);
    c.glAttachShader(prog, fs);
    c.glBindAttribLocation(prog, 0, "pos");
    c.glLinkProgram(prog);
    var ok: c.GLint = 0;
    c.glGetProgramiv(prog, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var buf: [1024]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetProgramInfoLog(prog, buf.len, &len, &buf);
        log.err("program link failed: {s}", .{buf[0..@intCast(len)]});
        c.glDeleteProgram(prog);
        return error.ProgramLinkFailed;
    }

    return .{
        .id = prog,
        .flip_y = c.glGetUniformLocation(prog, "flip_y"),
        .tex = c.glGetUniformLocation(prog, "tex"),
    };
}

/// Whether we can present right now. While a flip is in flight we must
/// wait for its completion event before queueing another.
pub fn canPresent(self: *const Presenter) bool {
    return !self.flip_pending;
}

pub const PresentError = error{
    /// The DMABUF could not be imported. The caller should ask the
    /// renderer to fall back to CPU frames.
    DmabufImportFailed,
} || PresentFailure;

const PresentFailure = error{PresentFailed};

/// Present a frame. If `frame` is null, the previous frame is drawn
/// again (used to repaint after a VT switch). Takes ownership of `frame`.
pub fn present(self: *Presenter, frame: ?ExportedFrame) PresentError!void {
    std.debug.assert(!self.flip_pending);

    self.makeCurrent() catch |err| {
        if (frame) |f| f.deinit();
        log.warn("failed to make presenter context current err={}", .{err});
        return error.PresentFailed;
    };

    var import_failed = false;
    if (frame) |f| switch (f) {
        .dmabuf => |dmabuf| {
            // The EGLImage holds its own reference to the buffer, so the
            // fds are always closed once the import attempt is done.
            defer dmabuf.deinit();
            self.importDmabuf(dmabuf) catch {
                import_failed = true;
            };
        },
        .memory => |memory| {
            defer memory.deinit();
            self.uploadMemory(memory);
        },
    };

    if (self.source == .none) {
        // Nothing to show yet; don't flip an undefined buffer.
        if (import_failed) return error.DmabufImportFailed;
        return;
    }

    self.draw();

    if (egl.c.eglSwapBuffers(self.display, self.egl_surface) != egl.c.EGL_TRUE) {
        log.warn("eglSwapBuffers failed err={}", .{egl.mustError()});
        return error.PresentFailed;
    }

    const bo = c.gbm_surface_lock_front_buffer(self.gbm_surface) orelse {
        log.warn("failed to lock GBM front buffer", .{});
        return error.PresentFailed;
    };

    const fb = fbForBo(bo) catch {
        c.gbm_surface_release_buffer(self.gbm_surface, bo);
        return error.PresentFailed;
    };

    if (self.needs_modeset) {
        var conn = self.drm.connector_id;
        if (c.drmModeSetCrtc(self.drm.fd(), self.drm.crtc_id, fb, 0, 0, &conn, 1, &self.drm.mode) != 0) {
            log.err("drmModeSetCrtc failed errno={}", .{util.errno()});
            c.gbm_surface_release_buffer(self.gbm_surface, bo);
            return error.PresentFailed;
        }
        log.info("modeset complete", .{});
        self.needs_modeset = false;
        // SetCrtc is synchronous: the new buffer is on screen now.
        if (self.front_bo) |old| c.gbm_surface_release_buffer(self.gbm_surface, old);
        self.front_bo = bo;
    } else {
        if (c.drmModePageFlip(
            self.drm.fd(),
            self.drm.crtc_id,
            fb,
            c.DRM_MODE_PAGE_FLIP_EVENT,
            self,
        ) != 0) {
            log.warn("drmModePageFlip failed errno={}", .{util.errno()});
            c.gbm_surface_release_buffer(self.gbm_surface, bo);
            return error.PresentFailed;
        }
        self.pending_bo = bo;
        self.flip_pending = true;
    }

    self.frame_count += 1;
    if (self.frame_count == 1) log.info("first frame presented", .{});
    if (import_failed) return error.DmabufImportFailed;
}

fn draw(self: *Presenter) void {
    const prog = switch (self.source) {
        .none => unreachable,
        .tex_2d => self.program_2d,
        .tex_ext => self.program_ext.?,
    };
    const target: c.GLenum = switch (self.source) {
        .none => unreachable,
        .tex_2d => c.GL_TEXTURE_2D,
        .tex_ext => c.GL_TEXTURE_EXTERNAL_OES,
    };
    const tex = switch (self.source) {
        .none => unreachable,
        .tex_2d => self.tex_2d,
        .tex_ext => self.tex_ext,
    };

    c.glViewport(0, 0, @intCast(self.drm.width()), @intCast(self.drm.height()));
    c.glClearColor(0, 0, 0, 1);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    c.glUseProgram(prog.id);
    c.glUniform1f(prog.flip_y, if (self.flip_y) 1.0 else 0.0);
    c.glUniform1i(prog.tex, 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(target, tex);

    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
    c.glEnableVertexAttribArray(0);
    c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    c.glDisableVertexAttribArray(0);
    c.glBindTexture(target, 0);

    glCheck("draw") catch {};
}

fn importDmabuf(self: *Presenter, dmabuf: Dmabuf) !void {
    const image_target = self.image_target_texture orelse return error.Unsupported;

    var attrs: [6 + Dmabuf.max_planes * 10 + 1]egl.c.EGLAttrib = undefined;
    var n: usize = 0;
    const add = struct {
        fn add(buf: []egl.c.EGLAttrib, i: *usize, k: c_int, v: egl.c.EGLAttrib) void {
            buf[i.*] = k;
            buf[i.* + 1] = v;
            i.* += 2;
        }
    }.add;

    add(&attrs, &n, egl.c.EGL_WIDTH, @intCast(dmabuf.width));
    add(&attrs, &n, egl.c.EGL_HEIGHT, @intCast(dmabuf.height));
    add(&attrs, &n, EGL_LINUX_DRM_FOURCC_EXT, @intCast(dmabuf.fourcc));
    for (0..dmabuf.planes.count) |i| {
        const p = plane_attrs[i];
        add(&attrs, &n, p.fd, dmabuf.planes.fds[i]);
        add(&attrs, &n, p.offset, dmabuf.planes.offsets[i]);
        add(&attrs, &n, p.pitch, dmabuf.planes.strides[i]);
        if (dmabuf.modifier != DRM_FORMAT_MOD_INVALID) {
            add(&attrs, &n, p.mod_lo, @intCast(dmabuf.modifier & 0xffffffff));
            add(&attrs, &n, p.mod_hi, @intCast(dmabuf.modifier >> 32));
        }
    }
    attrs[n] = egl.c.EGL_NONE;

    const image = egl.c.eglCreateImage(self.display, null, EGL_LINUX_DMA_BUF_EXT, null, &attrs);
    if (image == null) {
        log.warn("eglCreateImage(dmabuf) failed fourcc=0x{x} modifier=0x{x} planes={} err={}", .{
            dmabuf.fourcc,
            dmabuf.modifier,
            dmabuf.planes.count,
            egl.mustError(),
        });
        return error.ImportFailed;
    }

    // Try GL_TEXTURE_2D first; some drivers only allow external images.
    _ = c.glGetError();
    c.glBindTexture(c.GL_TEXTURE_2D, self.tex_2d);
    image_target(c.GL_TEXTURE_2D, image);
    var source: Source = .tex_2d;
    if (c.glGetError() != c.GL_NO_ERROR) {
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        if (self.program_ext == null) {
            _ = egl.c.eglDestroyImage(self.display, image);
            log.warn("dmabuf can't be bound as GL_TEXTURE_2D and external images are unsupported", .{});
            return error.ImportFailed;
        }
        c.glBindTexture(c.GL_TEXTURE_EXTERNAL_OES, self.tex_ext);
        image_target(c.GL_TEXTURE_EXTERNAL_OES, image);
        c.glBindTexture(c.GL_TEXTURE_EXTERNAL_OES, 0);
        if (c.glGetError() != c.GL_NO_ERROR) {
            _ = egl.c.eglDestroyImage(self.display, image);
            log.warn("dmabuf can't be bound as an external texture either", .{});
            return error.ImportFailed;
        }
        source = .tex_ext;
    } else {
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    // The previous image is no longer referenced by any texture.
    if (self.image != null) _ = egl.c.eglDestroyImage(self.display, self.image);
    self.image = image;
    self.source = source;
    // tex_2d now aliases the image; force a realloc on the next upload.
    self.upload_w = 0;
    self.upload_h = 0;
}

fn uploadMemory(self: *Presenter, memory: ExportedFrame.Memory) void {
    c.glBindTexture(c.GL_TEXTURE_2D, self.tex_2d);
    if (self.upload_w != memory.width or self.upload_h != memory.height) {
        // Re-specifying the texture also detaches any EGLImage from it.
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            @intCast(memory.width),
            @intCast(memory.height),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            memory.pixels.ptr,
        );
        self.upload_w = memory.width;
        self.upload_h = memory.height;
    } else {
        c.glTexSubImage2D(
            c.GL_TEXTURE_2D,
            0,
            0,
            0,
            @intCast(memory.width),
            @intCast(memory.height),
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            memory.pixels.ptr,
        );
    }
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
    if (self.image != null) {
        _ = egl.c.eglDestroyImage(self.display, self.image);
        self.image = null;
    }
    self.source = .tex_2d;
    glCheck("upload") catch {};
}

/// Read and dispatch DRM events (page flip completions).
pub fn dispatchDrmEvents(self: *Presenter) void {
    var ctx: c.drmEventContext = std.mem.zeroes(c.drmEventContext);
    ctx.version = 2;
    ctx.page_flip_handler = pageFlipHandler;
    if (c.drmHandleEvent(self.drm.fd(), &ctx) != 0) {
        log.warn("drmHandleEvent failed errno={}", .{util.errno()});
    }
}

fn pageFlipHandler(
    _: c_int,
    _: c_uint,
    _: c_uint,
    _: c_uint,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const self: *Presenter = @ptrCast(@alignCast(userdata orelse return));
    self.flipComplete();
}

fn flipComplete(self: *Presenter) void {
    if (!self.flip_pending) return;
    self.flip_pending = false;
    if (self.front_bo) |old| c.gbm_surface_release_buffer(self.gbm_surface, old);
    self.front_bo = self.pending_bo;
    self.pending_bo = null;
}

/// Called when we regain the seat. The display may have been
/// reconfigured by whoever had it, so the next present does a full
/// modeset.
pub fn resume_(self: *Presenter) void {
    self.needs_modeset = true;
}

/// Called when we lose the seat. A flip queued just before still
/// completes in the kernel, but we may never read its event, so treat it
/// as done.
pub fn suspend_(self: *Presenter) void {
    self.flipComplete();
}

/// Get (or create and cache) the DRM framebuffer for a GBM buffer.
fn fbForBo(bo: *c.struct_gbm_bo) !u32 {
    if (c.gbm_bo_get_user_data(bo)) |data| return @intCast(@intFromPtr(data));

    const dev = c.gbm_bo_get_device(bo);
    const drm_fd = c.gbm_device_get_fd(dev);
    const w = c.gbm_bo_get_width(bo);
    const h = c.gbm_bo_get_height(bo);
    const format = c.gbm_bo_get_format(bo);
    const modifier = c.gbm_bo_get_modifier(bo);
    const n_planes: usize = @intCast(c.gbm_bo_get_plane_count(bo));

    var handles: [4]u32 = @splat(0);
    var strides: [4]u32 = @splat(0);
    var offsets: [4]u32 = @splat(0);
    var modifiers: [4]u64 = @splat(0);
    for (0..@min(n_planes, 4)) |i| {
        handles[i] = c.gbm_bo_get_handle_for_plane(bo, @intCast(i)).u32;
        strides[i] = c.gbm_bo_get_stride_for_plane(bo, @intCast(i));
        offsets[i] = c.gbm_bo_get_offset(bo, @intCast(i));
        modifiers[i] = modifier;
    }

    var fb: u32 = 0;
    var ok = false;
    if (modifier != DRM_FORMAT_MOD_INVALID) {
        ok = c.drmModeAddFB2WithModifiers(drm_fd, w, h, format, &handles, &strides, &offsets, &modifiers, &fb, c.DRM_MODE_FB_MODIFIERS) == 0;
    }
    if (!ok) ok = c.drmModeAddFB2(drm_fd, w, h, format, &handles, &strides, &offsets, &fb, 0) == 0;
    if (!ok) ok = c.drmModeAddFB(drm_fd, w, h, 24, 32, strides[0], handles[0], &fb) == 0;
    if (!ok) {
        log.err("failed to create DRM framebuffer errno={}", .{util.errno()});
        return error.AddFbFailed;
    }

    c.gbm_bo_set_user_data(bo, @ptrFromInt(fb), destroyBoFb);
    return fb;
}

fn destroyBoFb(bo: ?*c.struct_gbm_bo, data: ?*anyopaque) callconv(.c) void {
    const fb: u32 = @intCast(@intFromPtr(data orelse return));
    const drm_fd = c.gbm_device_get_fd(c.gbm_bo_get_device(bo));
    _ = c.drmModeRmFB(drm_fd, fb);
}
