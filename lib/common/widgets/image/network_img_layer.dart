import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

class NetworkImgLayer extends StatelessWidget {
  const NetworkImgLayer({
    super.key,
    required this.src,
    required this.width,
    required this.height,
    this.type = .def,
    this.fadeOutDuration = const Duration(milliseconds: 120),
    this.fadeInDuration = const Duration(milliseconds: 120),
    this.quality = 1,
    this.borderRadius = Style.mdRadius,
    this.getPlaceHolder,
    this.fit = .cover,
    this.alignment = .center,
    this.cacheWidth,
  });

  final String? src;
  final double width;
  final double height;
  final ImageType type;
  final Duration fadeOutDuration;
  final Duration fadeInDuration;
  final int quality;
  final BorderRadius borderRadius;
  final ValueGetter<Widget>? getPlaceHolder;
  final BoxFit fit;
  final Alignment alignment;
  final bool? cacheWidth;

  static Color? reduceLuxColor = Pref.reduceLuxColor;
  static bool reduce = false;

  @override
  Widget build(BuildContext context) {
    final isEmote = type == ImageType.emote;
    final isAvatar = type == ImageType.avatar;
    if (src?.isNotEmpty == true) {
      final optimizeForIPad = PlatformUtils.isIPad(context);
      Widget child;
      if (optimizeForIPad && !isAvatar) {
        child = _IPadDeferredNetworkImage(
          imageId: Object.hash(src, width, height, quality, cacheWidth),
          imageBuilder: (context) => _buildImage(
            context,
            isEmote: isEmote,
            isAvatar: isAvatar,
          ),
          placeholderBuilder: (context) =>
              getPlaceHolder?.call() ??
              _placeholder(
                context,
                isEmote: isEmote,
                isAvatar: isAvatar,
              ),
        );
      } else {
        child = _buildImage(
          context,
          isEmote: isEmote,
          isAvatar: isAvatar,
        );
      }
      if (isEmote) {
        return child;
      } else if (isAvatar) {
        return ClipOval(child: child);
      } else {
        return ClipRRect(borderRadius: borderRadius, child: child);
      }
    } else {
      return getPlaceHolder?.call() ??
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar);
    }
  }

  Widget _buildImage(
    BuildContext context, {
    required bool isEmote,
    required bool isAvatar,
  }) {
    int? memCacheWidth, memCacheHeight;
    if (cacheWidth ?? width <= height) {
      memCacheWidth = width.cacheSize(context);
    } else {
      memCacheHeight = height.cacheSize(context);
    }
    return CachedNetworkImage(
      imageUrl: ImageUtils.thumbnailUrl(src, quality),
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      fit: fit,
      alignment: alignment,
      fadeOutDuration: fadeOutDuration,
      fadeInDuration: fadeInDuration,
      filterQuality: FilterQuality.low,
      placeholder: (_, _) =>
          getPlaceHolder?.call() ??
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar),
      errorWidget: (_, _, _) =>
          _placeholder(context, isEmote: isEmote, isAvatar: isAvatar),
      colorBlendMode: reduce ? BlendMode.modulate : null,
      color: reduce ? reduceLuxColor : null,
    );
  }

  Widget _placeholder(
    BuildContext context, {
    required bool isEmote,
    required bool isAvatar,
  }) {
    return Container(
      width: width,
      height: height,
      clipBehavior: isEmote ? Clip.none : Clip.antiAlias,
      decoration: BoxDecoration(
        shape: isAvatar ? BoxShape.circle : BoxShape.rectangle,
        color: Theme.of(
          context,
        ).colorScheme.onInverseSurface.withValues(alpha: 0.4),
        borderRadius: isEmote || isAvatar ? null : borderRadius,
      ),
      child: Center(
        child: Image.asset(
          isAvatar ? Assets.avatarPlaceHolder : Assets.loading,
          width: width,
          height: height,
          cacheWidth: width.cacheSize(context),
          colorBlendMode: reduce ? BlendMode.modulate : null,
          color: reduce ? reduceLuxColor : null,
        ),
      ),
    );
  }
}

/// Defers creating a new image decoder while an iPad list is moving quickly.
///
/// Flutter's scroll physics exposes a velocity-based recommendation specifically
/// for deferring expensive work. Existing images remain mounted; only newly
/// revealed images wait until the fling ends, keeping decode and texture upload
/// off the gesture's critical frames.
class _IPadDeferredNetworkImage extends StatefulWidget {
  const _IPadDeferredNetworkImage({
    required this.imageId,
    required this.imageBuilder,
    required this.placeholderBuilder,
  });

  final int imageId;
  final WidgetBuilder imageBuilder;
  final WidgetBuilder placeholderBuilder;

  @override
  State<_IPadDeferredNetworkImage> createState() =>
      _IPadDeferredNetworkImageState();
}

class _IPadDeferredNetworkImageState
    extends State<_IPadDeferredNetworkImage> {
  ScrollPosition? _position;
  bool _loadImage = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPosition = Scrollable.maybeOf(
      context,
      axis: Axis.vertical,
    )?.position;
    if (identical(nextPosition, _position)) return;
    _position?.isScrollingNotifier.removeListener(_handleScrollingChanged);
    _position = nextPosition;
    _position?.isScrollingNotifier.addListener(_handleScrollingChanged);
  }

  @override
  void didUpdateWidget(covariant _IPadDeferredNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageId != widget.imageId) {
      _loadImage = false;
    }
  }

  void _handleScrollingChanged() {
    if (!_loadImage && !(_position?.isScrollingNotifier.value ?? false)) {
      setState(() => _loadImage = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loadImage) {
      _loadImage = !Scrollable.recommendDeferredLoadingForContext(
        context,
        axis: Axis.vertical,
      );
    }
    return _loadImage
        ? widget.imageBuilder(context)
        : widget.placeholderBuilder(context);
  }

  @override
  void dispose() {
    _position?.isScrollingNotifier.removeListener(_handleScrollingChanged);
    _position = null;
    super.dispose();
  }
}
