export enum AppThemeKind {
  BLUE = 'blue',
  GREEN = 'green',
  YELLOW = 'yellow',
  PINK = 'pink',
  ORANGE = 'orange',
  PURPLE = 'purple'
}

export class AppThemeOption {
  id: AppThemeKind;
  title: string;
  color: string;

  constructor(id: AppThemeKind, title: string, color: string) {
    this.id = id;
    this.title = title;
    this.color = color;
  }
}

export const APP_THEME_OPTIONS: AppThemeOption[] = [
  new AppThemeOption(AppThemeKind.BLUE, '蓝色', '#0A84FF'),
  new AppThemeOption(AppThemeKind.GREEN, '绿色', '#30D158'),
  new AppThemeOption(AppThemeKind.YELLOW, '黄色', '#FFD60A'),
  new AppThemeOption(AppThemeKind.PINK, '粉色', '#FF375F'),
  new AppThemeOption(AppThemeKind.ORANGE, '橙色', '#FF9F0A'),
  new AppThemeOption(AppThemeKind.PURPLE, '紫色', '#BF5AF2')
];

export function accentColorFor(theme: string): string {
  switch (theme) {
    case AppThemeKind.GREEN:
      return '#30D158';
    case AppThemeKind.YELLOW:
      return '#FFD60A';
    case AppThemeKind.PINK:
      return '#FF375F';
    case AppThemeKind.ORANGE:
      return '#FF9F0A';
    case AppThemeKind.PURPLE:
      return '#BF5AF2';
    case AppThemeKind.BLUE:
    default:
      return '#0A84FF';
  }
}

export function accentColorWithAlpha(theme: string, alpha: string): string {
  return `#${alpha}${accentColorFor(theme).slice(1)}`;
}
