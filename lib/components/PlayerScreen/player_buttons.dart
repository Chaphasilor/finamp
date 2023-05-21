import 'package:audio_service/audio_service.dart';
import 'package:finamp/components/PlayerScreen/player_buttons_repeating.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/components/PlayerScreen/player_buttons_shuffle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

import '../../models/jellyfin_models.dart';
import '../../services/media_state_stream.dart';
import '../../services/music_player_background_task.dart';
import '../../services/player_screen_theme_provider.dart';

class PlayerButtons extends ConsumerWidget {
  const PlayerButtons({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    final queueService = GetIt.instance<QueueService>();

    return IconTheme(
      data: IconThemeData(
        color: ref.watch(playerScreenThemeProvider) ??
            (Theme.of(context).brightness == Brightness.light
                ? Colors.black
                : Colors.white),
      ),
      child: StreamBuilder<MediaState>(
        stream: mediaStateStream,
        builder: (context, snapshot) {
          final mediaState = snapshot.data;
          final playbackState = mediaState?.playbackState;
          final item = mediaState?.mediaItem?.extras?["itemJson"] == null
              ? null
              : BaseItemDto.fromJson(
                  mediaState!.mediaItem!.extras!["itemJson"]);

          return Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            textDirection: TextDirection.ltr,
            children: [
              PlayerButtonsRepeating(),
              IconButton(
                icon: const Icon(TablerIcons.player_skip_back),
                // onPressed: () async => queueService.previousTrack()
                onPressed: () async => audioHandler.skipToPrevious()
              ),
              _RoundedIconButton(
                width: 75,
                height: 75,
                onTap: playbackState != null
                    ? () async {
                        if (playbackState.playing) {
                          await audioHandler.pause();
                        } else {
                          await audioHandler.play();
                        }
                      }
                  : null,
                icon: Icon(
                  playbackState == null || playbackState.playing
                      ? TablerIcons.player_pause
                      : TablerIcons.player_play,
                  size: 35),
              ),
              IconButton(
                icon: const Icon(TablerIcons.player_skip_forward),
                onPressed: playbackState != null
                    // ? () async => queueService.nextTrack()
                    ? () async => audioHandler.skipToNext()
                    : null,
              ),
              PlayerButtonsShuffle()
            ],
          );
        },
      )
    );
  }
}

class _RoundedIconButton extends StatelessWidget {
  const _RoundedIconButton({
    Key? key,
    required this.icon,
    this.borderRadius,
    this.width = 48,
    this.height = 48,
    this.onTap,
  }) : super(key: key);

  final Widget icon;
  final BorderRadius? borderRadius;
  final double width;
  final double height;
  final VoidCallback? onTap;

  Widget _addDropShadow(Icon icon, BuildContext context) {
    // If only Icon had a .copyWith() function lol
    return Transform.translate(
      offset: icon.icon?.fontFamily == "tabler-icons"
          ? const Offset(1, -1)
          : Offset.zero,
      child: Icon(
        icon.icon,
        color: icon.color,
        key: icon.key,
        semanticLabel: icon.semanticLabel,
        size: icon.size,
        textDirection: icon.textDirection,
        shadows: icon.shadows ??
            [
              BoxShadow(
                blurRadius: 2,
                offset: const Offset(0, 2),
                color: (icon.color ?? IconTheme.of(context).color)!
                    .withOpacity(0.25),
              )
            ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _borderRadius = borderRadius ?? BorderRadius.circular(height);
    final _icon = icon is Icon ? _addDropShadow(icon as Icon, context) : icon;
    return SizedBox(
      width: width,
      height: height,
      child: Material(
        borderRadius: _borderRadius,
        color: IconTheme.of(context).color!.withOpacity(0.15),
        child: InkWell(
          borderRadius: _borderRadius,
          onTap: onTap,
          child: _icon,
        ),
      ),
    );
  }
}
