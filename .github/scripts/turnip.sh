#!/bin/bash -e

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

WORKDIR="$(pwd)/turnip_workdir"

log_info() {
	echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
	echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
	echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PATCHES_DIR="$SCRIPT_DIR/patches"

if [ -z "${MESA_VERSION}" ]; then
	log_error "MESA_VERSION environment variable is required but not provided"
	log_error "Please set MESA_VERSION before running this script"
	echo ""
	echo "Example usage:"
	echo "  MESA_VERSION=25.1.5 $0 aarch64"
	exit 1
fi

MESA_ARCHIVE_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"

BUILD_ARCHITECTURES=()

show_usage() {
	echo "Usage: MESA_VERSION=x.x.x $0 [architecture]"
	echo ""
	echo "Arguments:"
	echo "  aarch64    Build only for ARM64 (64-bit)"
	echo "  arm        Build only for ARM (32-bit) - requires cross-compilation setup"
	echo "  <none>     Build for aarch64 only (default)"
	echo ""
	echo "Environment Variables:"
	echo "  MESA_VERSION    Mesa version to build (REQUIRED - no default)"
	echo ""
	echo "Examples:"
	echo "  MESA_VERSION=25.1.5 $0              # Build for aarch64"
	echo "  MESA_VERSION=25.1.5 $0 aarch64      # Build for ARM64"
	echo ""
	echo "Patches:"
	echo "  The script will automatically apply patches from the 'patches' directory"
	echo "  located in the same directory as this script. Patches are applied in"
	echo "  numerical order (0001, 0002, 0003, etc.)"
	exit 1
}

parse_arguments() {
	log_info "Using Mesa version: $MESA_VERSION"

	if [ $# -eq 0 ]; then
		# No arguments - build for aarch64 only
		BUILD_ARCHITECTURES=(aarch64)
		log_info "No architecture specified - building for aarch64"
	elif [ $# -eq 1 ]; then
		case "$1" in
		aarch64)
			BUILD_ARCHITECTURES=(aarch64)
			log_info "Building for ARM64 (aarch64) only"
			;;
		arm)
			log_error "ARM 32-bit builds require cross-compilation setup"
			log_error "This is not currently supported in native build mode"
			return 0
			;;
		--help | -h)
			show_usage
			;;
		*)
			log_error "Invalid architecture: $1"
			log_error "Valid options: aarch64"
			show_usage
			;;
		esac
	else
		log_error "Too many arguments"
		show_usage
	fi
}

prepare_mesa() {
	log_info "Preparing Mesa source..."

	cd "$WORKDIR"
	local archive_file="mesa-${MESA_VERSION}.tar.xz"
	local extracted_dir="mesa-${MESA_VERSION}"

	if [ ! -f "$archive_file" ]; then
		log_info "Downloading Mesa $MESA_VERSION archive..."
		curl -L "$MESA_ARCHIVE_URL" \
			--output "$archive_file" \
			--progress-bar

		if [ ! -f "$archive_file" ]; then
			log_error "Failed to download Mesa archive"
			exit 1
		fi
		log_success "Mesa archive downloaded"
	else
		log_info "Using existing Mesa archive: $archive_file"
	fi

	if [ -d mesa ]; then
		log_warning "Removing existing Mesa directory"
		rm -rf mesa
	fi

	log_info "Extracting Mesa archive..."
	tar -xf "$archive_file"

	if [ -d "$extracted_dir" ]; then
		mv "$extracted_dir" mesa
	else
		log_error "Extracted directory not found: $extracted_dir"
		exit 1
	fi

	cd mesa

	log_success "Mesa $MESA_VERSION prepared"
}

apply_patches() {
	log_info "Checking for patches in: $PATCHES_DIR"

	if [ ! -d "$PATCHES_DIR" ]; then
		log_info "No patches directory found, skipping patch application"
		return 0
	fi

	cd "$WORKDIR/mesa"

	local patch_files=()
	while IFS= read -r -d '' patch_file; do
		patch_files+=("$patch_file")
	done < <(find "$PATCHES_DIR" -name "*.patch" -type f -print0 | sort -z)

	if [ ${#patch_files[@]} -eq 0 ]; then
		log_info "No patch files found in patches directory, skipping patch application"
		return 0
	fi

	log_info "Found ${#patch_files[@]} patch file(s) to apply"

	for patch_file in "${patch_files[@]}"; do
		local patch_name
		patch_name=$(basename "$patch_file")
		log_info "Applying patch: $patch_name"

		if git apply --check "$patch_file" >/dev/null 2>&1; then
			if git apply "$patch_file"; then
				log_success "Successfully applied patch: $patch_name"
			else
				log_error "Failed to apply patch: $patch_name"
				log_error "Patch application failed, exiting"
				exit 1
			fi
		else
			log_warning "Git apply check failed for $patch_name, trying patch command"
			if patch -p1 --dry-run <"$patch_file" >/dev/null 2>&1; then
				if patch -p1 <"$patch_file"; then
					log_success "Successfully applied patch: $patch_name"
				else
					log_error "Failed to apply patch: $patch_name"
					log_error "Patch application failed, exiting"
					exit 1
				fi
			else
				log_error "Patch $patch_name cannot be applied (dry-run failed)"
				log_error "This may indicate the patch is incompatible with Mesa version $MESA_VERSION"
				log_error "Patch application failed, exiting"
				exit 1
			fi
		fi
	done

	log_success "All patches applied successfully"
}

build_for_architecture() {
	local arch="$1"

	log_info "Building Turnip for $arch architecture..."

	cd "$WORKDIR/mesa"

	local build_dir="build-${arch}"

	if [ -d "$build_dir" ]; then
		log_info "Cleaning existing build directory..."
		rm -rf "$build_dir"
	fi

	log_info "Configuring Mesa with meson..."

	# Setup ccache
	if [ -n "${CCACHE_DIR}" ]; then
		export CCACHE_DIR
		log_info "Using ccache directory: $CCACHE_DIR"
	fi

	# Use LLVM 20 if available, otherwise use system default
	local llvm_config=""
	if [ -f "/usr/lib/llvm-20/bin/llvm-config" ]; then
		llvm_config="/usr/lib/llvm-20/bin/llvm-config"
		export LLVM_CONFIG="$llvm_config"
		log_info "Using LLVM 20: $llvm_config"
	fi

	# Native build configuration based on the Build workflow
	CC="ccache gcc" CXX="ccache g++" meson setup "$build_dir" \
		--prefix=/usr \
		-Dplatforms=x11,wayland \
		-Dgallium-drivers=freedreno,zink,virgl,llvmpipe \
		-Dgallium-va=disabled \
		-Dgallium-mediafoundation=disabled \
		-Dvulkan-drivers=freedreno \
		-Dvulkan-layers= \
		-Degl=enabled \
		-Dgles2=enabled \
		-Dglvnd=enabled \
		-Dglx=dri \
		-Dlibunwind=disabled \
		-Dintel-rt=disabled \
		-Dmicrosoft-clc=disabled \
		-Dvalgrind=disabled \
		-Dgles1=disabled \
		-Dfreedreno-kmds=kgsl \
		-Dbuildtype=release

	log_info "Building Mesa..."
	ninja -C "$build_dir" -j "$(nproc)"

	log_success "Build completed for $arch"
}

package_architecture() {
	local arch="$1"

	log_info "Packaging Turnip for $arch..."

	local package_dir="$WORKDIR/turnip_package_${arch}"
	mkdir -p "$package_dir"
	rm -rf "${package_dir:?}"/*

	cd "$WORKDIR/mesa"

	log_info "Installing Mesa to temporary directory..."
	DESTDIR="$package_dir" meson install -C "build-${arch}"

	log_success "Packaged Mesa installation for $arch"
}

create_package() {
	local arch="$1"

	log_info "Creating zip package for $arch..."

	local package_name="turnip-${MESA_VERSION}-${arch}"
	local package_dir="$WORKDIR/turnip_package_${arch}"

	cd "$package_dir"

	# Create zip from the installed files
	zip -r "$WORKDIR/${package_name}.zip" .

	if [ -f "$WORKDIR/${package_name}.zip" ]; then
		log_success "Package created: $WORKDIR/${package_name}.zip"
		log_info "Package size: $(du -h "$WORKDIR/${package_name}.zip" | cut -f1)"
		log_info "Package contents:"
		unzip -l "$WORKDIR/${package_name}.zip" | head -20
		echo ""
	else
		log_error "Package creation failed for $arch"
		return 1
	fi
}

main() {
	parse_arguments "$@"

	log_info "Starting Turnip builder for architectures: ${BUILD_ARCHITECTURES[*]} (Mesa $MESA_VERSION)"
	log_info "Build mode: Native Linux build (no Android NDK)"

	mkdir -p "$WORKDIR"
	cd "$WORKDIR"

	prepare_mesa
	apply_patches

	local successful_builds=()
	local failed_builds=()

	for arch in "${BUILD_ARCHITECTURES[@]}"; do
		log_info "Processing architecture: $arch"

		if build_for_architecture "$arch"; then
			log_success "Successfully built for $arch"

			if package_architecture "$arch"; then
				if create_package "$arch"; then
					successful_builds+=("$arch")
					log_success "Successfully packaged $arch"
				else
					failed_builds+=("$arch")
					log_error "Failed to create package for $arch"
				fi
			else
				failed_builds+=("$arch")
				log_error "Failed to package $arch"
			fi
		else
			failed_builds+=("$arch")
			log_error "Failed to build for $arch"
		fi
		echo ""
	done

	log_info "Build Summary:"
	if [ ${#successful_builds[@]} -gt 0 ]; then
		log_success "Successfully built and packaged: ${successful_builds[*]}"
		for arch in "${successful_builds[@]}"; do
			local package_name="turnip-${MESA_VERSION}-${arch}.zip"
			log_info "  → $WORKDIR/$package_name"
		done
	fi

	if [ ${#failed_builds[@]} -gt 0 ]; then
		log_error "Failed builds: ${failed_builds[*]}"
		exit 1
	fi

	log_success "All operations completed successfully!"
	log_info "Output directory: $WORKDIR"
}

main "$@"
