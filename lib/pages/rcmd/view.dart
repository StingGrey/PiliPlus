import 'package:PiliPlus/common/skeleton/video_card_v.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_v.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/performance_probe.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class RcmdPage extends StatefulWidget {
  const RcmdPage({super.key});

  @override
  State<RcmdPage> createState() => _RcmdPageState();
}

class _RcmdPageState extends State<RcmdPage>
    with AutomaticKeepAliveClientMixin {
  final RcmdController controller = Get.put(RcmdController());

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = ColorScheme.of(context);
    return Container(
      clipBehavior: .hardEdge,
      margin: const .symmetric(horizontal: Style.safeSpace),
      decoration: const BoxDecoration(borderRadius: Style.mdRadius),
      child: refreshIndicator(
        onRefresh: controller.onRefresh,
        child: CustomScrollView(
          controller: controller.scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const .only(top: Style.cardSpace, bottom: 100),
              sliver: Obx(
                () => _buildBody(colorScheme, controller.loadingState.value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  late final gridDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Pref.recommendCardWidth,
    childAspectRatio: Style.aspectRatio,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(90),
  );

  Widget _buildBody(
    ColorScheme colorScheme,
    LoadingState<List<dynamic>?> loadingState,
  ) {
    return switch (loadingState) {
      Loading() => _buildSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? ValueListenableBuilder<RcmdRenderMode>(
                valueListenable: PerformanceProbe.rcmdRenderMode,
                builder: (context, renderMode, _) => SliverGrid.builder(
                  gridDelegate: gridDelegate,
                  itemBuilder: (context, index) {
                  if (index == response.length - 1) {
                    controller.onLoadMore();
                  }
                  if (controller.lastRefreshAt != null) {
                    if (controller.lastRefreshAt == index) {
                      return GestureDetector(
                        onTap: () => controller
                          ..animateToTop()
                          ..onRefresh(),
                        child: Card(
                          child: Container(
                            alignment: Alignment.center,
                            padding: const .symmetric(horizontal: 10),
                            child: Text(
                              '上次看到这里\n点击刷新',
                              textAlign: .center,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    final actualIndex = index > controller.lastRefreshAt!
                        ? index - 1
                        : index;
                    final videoItem =
                        response[actualIndex] as BaseRcmdVideoItemModel;
                    return _CachedVideoCard(
                      key: ValueKey(
                        '${_videoCardKey(videoItem)}:$actualIndex',
                      ),
                      videoItem: videoItem,
                      renderMode: renderMode,
                      onRemove: () {
                        if (controller.lastRefreshAt != null &&
                            actualIndex < controller.lastRefreshAt!) {
                          controller.lastRefreshAt =
                              controller.lastRefreshAt! - 1;
                        }
                        controller.loadingState
                          ..value.data!.removeAt(actualIndex)
                          ..refresh();
                      },
                    );
                  } else {
                    final videoItem =
                        response[index] as BaseRcmdVideoItemModel;
                    return _CachedVideoCard(
                      key: ValueKey('${_videoCardKey(videoItem)}:$index'),
                      videoItem: videoItem,
                      renderMode: renderMode,
                      onRemove: () => controller.loadingState
                        ..value.data!.removeAt(index)
                        ..refresh(),
                    );
                  }
                  },
                  itemCount: controller.lastRefreshAt != null
                      ? response.length + 1
                      : response.length,
                  addAutomaticKeepAlives: false,
                ),
              )
            : HttpError(onReload: controller.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget get _buildSkeleton => SliverGrid.builder(
    gridDelegate: gridDelegate,
    itemBuilder: (context, index) => const VideoCardVSkeleton(),
    itemCount: 10,
    addAutomaticKeepAlives: false,
  );
}

String _videoCardKey(BaseRcmdVideoItemModel item) =>
    '${item.goto}:${item.bvid ?? item.param ?? item.aid ?? item.uri}';

class _CachedVideoCard extends StatefulWidget {
  const _CachedVideoCard({
    super.key,
    required this.videoItem,
    required this.renderMode,
    required this.onRemove,
  });

  final BaseRcmdVideoItemModel videoItem;
  final RcmdRenderMode renderMode;
  final VoidCallback onRemove;

  @override
  State<_CachedVideoCard> createState() => _CachedVideoCardState();
}

class _CachedVideoCardState extends State<_CachedVideoCard> {
  late Widget _card;

  @override
  void initState() {
    super.initState();
    _card = _buildCard();
  }

  Widget _buildCard() => VideoCardV(
    videoItem: widget.videoItem,
    renderMode: widget.renderMode,
    onRemove: () => widget.onRemove(),
  );

  @override
  void didUpdateWidget(covariant _CachedVideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.videoItem, widget.videoItem) ||
        oldWidget.renderMode != widget.renderMode) {
      _card = _buildCard();
    }
  }

  @override
  Widget build(BuildContext context) => _card;
}
