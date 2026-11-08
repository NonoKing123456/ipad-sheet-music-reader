import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// A local, nonmodal page input. Opening the keyboard never resizes the stage.
class ReaderPageNumberButton extends StatefulWidget {
  const ReaderPageNumberButton({
    super.key,
    required this.page,
    required this.pageCount,
    required this.onJump,
    this.label,
    this.enabled = true,
    this.target = ScoreLayout.touchTarget,
    this.onOpenChanged,
  });
  final int page, pageCount;
  final String? label;
  final bool enabled;
  final double target;
  final ValueChanged<int> onJump;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<ReaderPageNumberButton> createState() => _ReaderPageNumberButtonState();
}

class _ReaderPageNumberButtonState extends State<ReaderPageNumberButton> {
  final _overlay = OverlayPortalController();
  final _link = LayerLink();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _tapGroup = Object();

  void _close() {
    if (!_overlay.isShowing) return;
    _overlay.hide();
    _focus.unfocus();
    widget.onOpenChanged?.call(false);
  }

  void _toggle() {
    if (_overlay.isShowing) return _close();
    _input.value = TextEditingValue(
      text: '${widget.page}',
      selection: TextSelection(
        baseOffset: 0,
        extentOffset: '${widget.page}'.length,
      ),
    );
    _overlay.show();
    widget.onOpenChanged?.call(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _overlay.isShowing) _focus.requestFocus();
    });
  }

  void _submit(String value) {
    final page = int.tryParse(value.trim());
    if (page == null || page < 1 || page > widget.pageCount) return;
    _close();
    widget.onJump(page);
  }

  @override
  void didUpdateWidget(covariant ReaderPageNumberButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _overlay.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _close();
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ScoreTokens.of(context);
    return TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) => _close(),
      child: OverlayPortal(
        controller: _overlay,
        overlayChildBuilder: (context) => Stack(
          fit: StackFit.expand,
          children: [
            // The reader listens to raw pointers. A transparent hit target
            // consumes the dismissing pointer before it can also turn a page.
            Positioned.fill(
              child: ExcludeSemantics(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => _close(),
                ),
              ),
            ),
            Positioned(
              width: ReaderNavigationTokens.pagePopoverWidth,
              height: ReaderNavigationTokens.pagePopoverHeight,
              child: CompositedTransformFollower(
                link: _link,
                showWhenUnlinked: false,
                targetAnchor: Alignment.bottomRight,
                followerAnchor: Alignment.topRight,
                child: TapRegion(
                  groupId: _tapGroup,
                  child: Material(
                    color: t.paper0,
                    elevation: ReaderNavigationTokens.pagePopoverElevation,
                    shape: RoundedRectangleBorder(
                      borderRadius: ScoreRadius.controlAll,
                      side: BorderSide(color: t.hair),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: ScoreSpace.sm,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Focus(
                              onKeyEvent: (_, event) {
                                if (event is KeyDownEvent &&
                                    event.logicalKey ==
                                        LogicalKeyboardKey.escape) {
                                  _close();
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: TextField(
                                key: const ValueKey('reader-page-input'),
                                controller: _input,
                                focusNode: _focus,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      signed: true,
                                    ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                textInputAction: TextInputAction.go,
                                onSubmitted: _submit,
                                decoration: InputDecoration(
                                  isDense: true,
                                  border: OutlineInputBorder(
                                    borderRadius: ScoreRadius.controlAll,
                                    borderSide: BorderSide(color: t.hair),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: ScoreRadius.controlAll,
                                    borderSide: BorderSide(color: t.hair),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: ScoreRadius.controlAll,
                                    borderSide: BorderSide(color: t.pine),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: ScoreSpace.xs,
                                    vertical: ScoreSpace.sm,
                                  ),
                                  semanticCounterText: 'PDF 实际页码',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: ScoreSpace.xs),
                          Text(
                            '/ ${widget.pageCount}',
                            style: ScoreText.note.copyWith(color: t.ink500),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        child: CompositedTransformTarget(
          link: _link,
          child: TextButton(
            key: const ValueKey('reader-page-number'),
            onPressed: widget.enabled ? _toggle : null,
            style: TextButton.styleFrom(
              foregroundColor: t.ink500,
              minimumSize: Size(0, widget.target),
              padding: const EdgeInsets.symmetric(horizontal: ScoreSpace.sm),
              splashFactory: NoSplash.splashFactory,
            ),
            child: Text(widget.label ?? '${widget.page} / ${widget.pageCount}'),
          ),
        ),
      ),
    );
  }
}
