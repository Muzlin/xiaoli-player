import 'package:flutter/material.dart';

/// 底部常驻播放控制条：当前曲目 + 橙色圆形控制按钮 + 音量/进度。
class PlayerBar extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final bool isPlaying;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPlayPause;

  const PlayerBar({
    super.key,
    this.title,
    this.subtitle,
    this.isPlaying = false,
    required this.onPrev,
    required this.onNext,
    required this.onPlayPause,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 84,
      color: const Color(0xFF2B2B33),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          SizedBox(
            width: 240,
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.music_note, color: cs.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title ?? '未在播放',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          _circle(Icons.skip_previous, onPrev, cs, big: false),
          const SizedBox(width: 16),
          _circle(isPlaying ? Icons.pause : Icons.play_arrow, onPlayPause, cs,
              big: true),
          const SizedBox(width: 16),
          _circle(Icons.skip_next, onNext, cs, big: false),
          const Spacer(),
          SizedBox(
            width: 240,
            child: Row(
              children: [
                const Icon(Icons.volume_up, color: Colors.white54, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbColor: cs.primary,
                      activeTrackColor: cs.primary,
                      inactiveTrackColor: Colors.white24,
                      overlayShape: SliderComponentShape.noOverlay,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(value: 0.7, onChanged: (_) {}),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circle(IconData icon, VoidCallback onTap, ColorScheme cs,
      {required bool big}) {
    final size = big ? 56.0 : 44.0;
    return Material(
      color: big ? cs.primary : const Color(0xFF3A3A44),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon,
              color: big ? Colors.white : cs.primary, size: big ? 32 : 24),
        ),
      ),
    );
  }
}
