CC      ?= gcc
CFLAGS  += -O2 -g -Wall -Wno-unused-parameter
PKG_CFLAGS := $(shell pkg-config --cflags libdrm wayland-client 2>/dev/null)
DRM_LIBS := $(shell pkg-config --libs libdrm)
WL_LIBS  := $(shell pkg-config --libs wayland-client)

SRC := src
BIN := bin
BLD := build

# 纯 DRM/ioctl 工具
DRM_TOOLS := kwinwrap drmatomic touchdraw setprop setbright connprops crtcstate \
             informats masterprobe planecrtc rawprobe kwinprobe atombisect \
             stageprobe replicate
UDEV_TOOLS := udevprobe udevmatch
# 需要 wayland-client + 随仓库分发的协议桩(免 wayland-scanner)
WAYLAND_TOOLS := touchtest touchinj

# storage-rebind 要在安卓的 init mount ns 里跑（安卓没有 glibc），必须静态；
# 它用的 mount fd API（open_tree/move_mount）也从 musl 头文件里拿。
REBIND_CC ?= musl-gcc

PROT_OBJS := $(BLD)/xdg-shell-protocol.o $(BLD)/fake-input-protocol.o

TOOLS := $(addprefix $(BIN)/,$(DRM_TOOLS) $(UDEV_TOOLS) $(WAYLAND_TOOLS)) $(BIN)/atomicspy.so

# CI 只编 TOOLS：storage-rebind 必须用 musl 静态编（安卓 init mount ns 里没有 glibc），
# 而 runner 上的 musl-gcc 只会产出 runner 架构的产物，跨编出来是错的东西。
all: $(TOOLS) $(BIN)/storage-rebind
ci: $(TOOLS)

$(BIN) $(BLD):
	mkdir -p $@

# 显式规则优先于下面的通用规则：静态、不链 libdrm
$(BIN)/storage-rebind: $(SRC)/storage-rebind.c | $(BIN)
	@command -v $(REBIND_CC) >/dev/null 2>&1 || { \
	  echo "storage-rebind 需要 $(REBIND_CC)（必须静态：安卓侧没有 glibc）。"; \
	  echo "装它：sudo apt install musl-tools ；只要其余工具就跑：make ci"; exit 127; }
	$(REBIND_CC) -static -O2 -Wall -o $@ $<

$(BLD)/%.o: $(SRC)/%.c | $(BLD)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -fPIC -c $< -o $@

$(BIN)/%: $(SRC)/%.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) $< -o $@ $(DRM_LIBS)

$(BIN)/udevprobe $(BIN)/udevmatch: $(BIN)/%: $(SRC)/%.c | $(BIN)
	$(CC) $(CFLAGS) $< -o $@ -ludev

$(addprefix $(BIN)/,$(WAYLAND_TOOLS)): $(BIN)/%: $(SRC)/%.c $(PROT_OBJS) | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) $< $(PROT_OBJS) -o $@ $(WL_LIBS)

$(BIN)/atomicspy.so: $(SRC)/atomic-spy.c | $(BIN)
	$(CC) $(CFLAGS) $(PKG_CFLAGS) -shared -fPIC $< -o $@ $(DRM_LIBS) -ldl

clean:
	rm -rf $(BLD)
	rm -f $(addprefix $(BIN)/,$(DRM_TOOLS) $(UDEV_TOOLS) $(WAYLAND_TOOLS)) $(BIN)/atomicspy.so

.PHONY: all ci clean
