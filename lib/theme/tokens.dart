import 'package:flutter/material.dart';

/// 设计令牌（Design Tokens）—— 界面样式的唯一事实来源。
///
/// 规则（见仓库根目录 DESIGN.md）：
/// 1. `lib/` 下**只有这个文件**允许出现 `Color(0x`、`fontSize:`、`BorderRadius.circular(`
///    的数值字面量。其余文件一律引用这里的令牌。
/// 2. 需要新令牌时，先加在这里（浅/深成对），再在组件里引用，不要在组件里就地调色。
/// 3. 谱面像素、批注笔迹颜色不属于界面样式，保持原值，不要迁移到这里。
///
/// 颜色命名表达**角色**，不表达明度：`paper` 是纸面层级，`ink` 是文字层级，
/// `pine` 是品牌色。这样深色模式下角色不变，只换取值。
@immutable
class ScoreTokens extends ThemeExtension<ScoreTokens> {
  const ScoreTokens({
    required this.paper0,
    required this.paper1,
    required this.paper2,
    required this.ink900,
    required this.ink700,
    required this.ink500,
    required this.ink300,
    required this.pine,
    required this.pineDeep,
    required this.pineWash,
    required this.warnBg,
    required this.warnInk,
    required this.dangerBg,
    required this.dangerInk,
  });

  /// 纸面 / 卡片 / 浮层底。
  final Color paper0;

  /// 页面与阅读底色。
  final Color paper1;

  /// 侧栏、输入框、凹陷区。
  final Color paper2;

  /// 主文字（对比度 ≥ 12:1）。
  final Color ink900;

  /// 正文（≥ 9:1）。
  final Color ink700;

  /// 辅助文字、次级图标（≥ 4.5:1，用于 13px 及以上）。
  final Color ink500;

  /// 仅禁用态与页码点；**不得**用于需要阅读的文字（< 3:1）。
  final Color ink300;

  /// 品牌色、选中态、主按钮。
  final Color pine;

  /// 深色强调（悬停、按下、品牌文字的加深版）。
  final Color pineDeep;

  /// 选中底、浅品牌色填充。
  final Color pineWash;

  /// 提示条底 / 文字。
  final Color warnBg;
  final Color warnInk;

  /// 错误条底 / 文字。
  final Color dangerBg;
  final Color dangerInk;

  static const ScoreTokens light = ScoreTokens(
    paper0: Color(0xFFFBFAF6),
    paper1: Color(0xFFF3F2EC),
    paper2: Color(0xFFE8E6DC),
    ink900: Color(0xFF17201C),
    ink700: Color(0xFF33413B),
    ink500: Color(0xFF5A6A63),
    ink300: Color(0xFF96A19B),
    pine: Color(0xFF236459),
    pineDeep: Color(0xFF1D5A4F),
    pineWash: Color(0xFFE2EBE7),
    warnBg: Color(0xFFFBF0DA),
    warnInk: Color(0xFF8A5A18),
    dangerBg: Color(0xFFF8E7E4),
    dangerInk: Color(0xFF9B4238),
  );

  static const ScoreTokens dark = ScoreTokens(
    paper0: Color(0xFF191E1B),
    paper1: Color(0xFF121614),
    paper2: Color(0xFF222824),
    ink900: Color(0xFFE8EBE7),
    ink700: Color(0xFFC2CCC7),
    ink500: Color(0xFFA7B2AC),
    ink300: Color(0xFF7F8C86),
    pine: Color(0xFF3E8577),
    pineDeep: Color(0xFF5FA394),
    pineWash: Color(0xFF1F332E),
    warnBg: Color(0xFF2A2116),
    warnInk: Color(0xFFE5B469),
    dangerBg: Color(0xFF2E1B18),
    dangerInk: Color(0xFFE39C90),
  );

  /// 取当前主题的令牌。未注册主题时回退到浅色，保证测试与独立页面不崩。
  static ScoreTokens of(BuildContext context) =>
      Theme.of(context).extension<ScoreTokens>() ?? light;

  @override
  ScoreTokens copyWith({
    Color? paper0,
    Color? paper1,
    Color? paper2,
    Color? ink900,
    Color? ink700,
    Color? ink500,
    Color? ink300,
    Color? pine,
    Color? pineDeep,
    Color? pineWash,
    Color? warnBg,
    Color? warnInk,
    Color? dangerBg,
    Color? dangerInk,
  }) => ScoreTokens(
    paper0: paper0 ?? this.paper0,
    paper1: paper1 ?? this.paper1,
    paper2: paper2 ?? this.paper2,
    ink900: ink900 ?? this.ink900,
    ink700: ink700 ?? this.ink700,
    ink500: ink500 ?? this.ink500,
    ink300: ink300 ?? this.ink300,
    pine: pine ?? this.pine,
    pineDeep: pineDeep ?? this.pineDeep,
    pineWash: pineWash ?? this.pineWash,
    warnBg: warnBg ?? this.warnBg,
    warnInk: warnInk ?? this.warnInk,
    dangerBg: dangerBg ?? this.dangerBg,
    dangerInk: dangerInk ?? this.dangerInk,
  );

  @override
  ScoreTokens lerp(covariant ScoreTokens? other, double t) {
    if (other == null) return this;
    return ScoreTokens(
      paper0: Color.lerp(paper0, other.paper0, t)!,
      paper1: Color.lerp(paper1, other.paper1, t)!,
      paper2: Color.lerp(paper2, other.paper2, t)!,
      ink900: Color.lerp(ink900, other.ink900, t)!,
      ink700: Color.lerp(ink700, other.ink700, t)!,
      ink500: Color.lerp(ink500, other.ink500, t)!,
      ink300: Color.lerp(ink300, other.ink300, t)!,
      pine: Color.lerp(pine, other.pine, t)!,
      pineDeep: Color.lerp(pineDeep, other.pineDeep, t)!,
      pineWash: Color.lerp(pineWash, other.pineWash, t)!,
      warnBg: Color.lerp(warnBg, other.warnBg, t)!,
      warnInk: Color.lerp(warnInk, other.warnInk, t)!,
      dangerBg: Color.lerp(dangerBg, other.dangerBg, t)!,
      dangerInk: Color.lerp(dangerInk, other.dangerInk, t)!,
    );
  }
}

/// 字阶：7 级，覆盖全部界面文字。
///
/// 用 [Style] 取样式，不要在组件里写 `fontSize:`。
/// 中文行高统一加宽（正文 1.7），避免拉丁字体行高在中文字面上挤成一坨。
abstract final class ScoreText {
  /// 页面大标题（欢迎页、空状态标题）。
  static const TextStyle display = TextStyle(
    fontSize: 28,
    height: 1.30,
    fontWeight: FontWeight.w600,
  );

  /// 区块标题。
  static const TextStyle title = TextStyle(
    fontSize: 20,
    height: 1.40,
    fontWeight: FontWeight.w600,
  );

  /// 列表主项、曲名、文件夹名。
  static const TextStyle headline = TextStyle(
    fontSize: 17,
    height: 1.50,
    fontWeight: FontWeight.w600,
  );

  /// 正文与输入框。
  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 1.70,
    fontWeight: FontWeight.w400,
  );

  /// 次要信息：列表副标题、路径、面包屑。
  static const TextStyle caption = TextStyle(
    fontSize: 13,
    height: 1.40,
    fontWeight: FontWeight.w500,
  );

  /// 提示条、注释文字。
  static const TextStyle note = TextStyle(
    fontSize: 12,
    height: 1.60,
    fontWeight: FontWeight.w400,
  );

  /// 角标、按钮内的小字。
  static const TextStyle micro = TextStyle(
    fontSize: 11,
    height: 1.40,
    fontWeight: FontWeight.w500,
  );
}

/// 4pt 间距网格。禁止 5 / 18 / 28 之类的奇数值。
abstract final class ScoreSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;
}

/// 三档圆角：控件 / 卡片 / 浮层。
abstract final class ScoreRadius {
  static const double control = 6;
  static const double card = 10;
  static const double overlay = 14;

  static const BorderRadius controlAll = BorderRadius.all(
    Radius.circular(control),
  );
  static const BorderRadius cardAll = BorderRadius.all(Radius.circular(card));
  static const BorderRadius overlayAll = BorderRadius.all(
    Radius.circular(overlay),
  );
}

/// 只两级阴影。阅读器的浮动工具条属于 depth0：半透明、无阴影、无描边。
abstract final class ScoreElevation {
  /// 卡片、需要离开背景一层的控件。
  static const List<BoxShadow> raised = [
    BoxShadow(
      color: Color(0x0F000000),
      blurRadius: 2,
      offset: Offset(0, 1),
    ),
  ];

  /// 菜单、对话框、被拖动的浮层。
  static const List<BoxShadow> overlay = [
    BoxShadow(
      color: Color(0x1A000000),
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
  ];
}

/// 动效时长。任何动画都用这三档之一。
abstract final class ScoreMotion {
  /// 颜色、透明度、图标切换。
  static const Duration micro = Duration(milliseconds: 120);

  /// 面板、抽屉、展开。
  static const Duration panel = Duration(milliseconds: 200);

  /// 翻页、页面转场。
  static const Duration page = Duration(milliseconds: 240);

  static const Curve curve = Curves.easeOutCubic;
}
