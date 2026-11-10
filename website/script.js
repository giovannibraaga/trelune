const copy = {
  "pt-BR": {
    brandHome: "Trelune, início",
    mainNavigation: "Navegação principal",
    navProduct: "O app",
    navHow: "Como funciona",
    downloadMac: "Baixar para Mac",
    toggleThemeToLight: "Ativar modo claro",
    toggleThemeToDark: "Ativar modo escuro",
    heroTitle: "Seu espaço<br>criativo.",
    heroDescription: "Planeje, organize e acompanhe suas publicações. Tudo em um só app nativo para macOS.",
    discoverApp: "Conheça o app",
    overviewPreview: "Prévia da tela de visão geral do Trelune",
    overviewAlt: "Visão geral do Trelune com métricas, evolução e desempenho por rede. Dados fictícios.",
    macRequirement: "macOS 14 OU SUPERIOR",
    openSource: "OPEN SOURCE",
    sectionApp: "01 / O APP",
    productTitle: "Tudo o que importa,<br>em perspectiva.",
    productDescription: "Acompanhe o calendário, as publicações e o desempenho do seu conteúdo em uma visão clara.",
    featurePlan: "Planeje com clareza",
    featurePlanDescription: "Veja o que está por vir e organize suas ideias.",
    featureTrack: "Acompanhe seu ritmo",
    featureTrackDescription: "Entenda o desempenho das suas publicações.",
    featureControl: "Você no controle",
    featureControlDescription: "Revise cada destino antes de publicar.",
    sectionHow: "02 / COMO FUNCIONA",
    processTitle: "Seu fluxo.<br>Suas regras.",
    processDescription: "Você escolhe o que vai ao ar. O Trelune mantém cada etapa organizada.",
    stepOrganize: "Organize",
    stepOrganizeDescription: "Reúna ideias, textos e mídia na biblioteca.",
    stepSchedule: "Programe",
    stepScheduleDescription: "Escolha os canais e planeje as datas no calendário.",
    stepPublish: "Publique",
    stepPublishDescription: "Revise cada destino e confirme antes de publicar.",
    processNote: "O app publica automaticamente enquanto estiver aberto. Nenhuma publicação acontece sem a sua confirmação.",
    downloadTitle: "Seu conteúdo,<br>no seu ritmo.",
    downloadDescription: "Um projeto independente e open source para o seu fluxo criativo.",
    downloadRequirement: "macOS 14 Sonoma ou superior",
    independentProject: "UM PROJETO INDEPENDENTE.",
    githubLink: "GITHUB ↗",
    footerDisclaimer: "© 2026 TRELUNE. SEM AFILIAÇÃO COM AS PLATAFORMAS."
  },
  en: {
    brandHome: "Trelune, home",
    mainNavigation: "Main navigation",
    navProduct: "The app",
    navHow: "How it works",
    downloadMac: "Download for Mac",
    toggleThemeToLight: "Switch to light mode",
    toggleThemeToDark: "Switch to dark mode",
    heroTitle: "Your creative<br>space.",
    heroDescription: "Plan, organize, and keep track of your posts in one native macOS app.",
    discoverApp: "Explore the app",
    overviewPreview: "Preview of the Trelune overview screen",
    overviewAlt: "Trelune overview with metrics, trends, and performance by social network. Fictional data.",
    macRequirement: "macOS 14 OR LATER",
    openSource: "OPEN SOURCE",
    sectionApp: "01 / THE APP",
    productTitle: "Everything that matters,<br>in perspective.",
    productDescription: "Follow your calendar, posts, and content performance in one clear view.",
    featurePlan: "Plan with clarity",
    featurePlanDescription: "See what is coming up and organize your ideas.",
    featureTrack: "Find your rhythm",
    featureTrackDescription: "Understand how your posts are performing.",
    featureControl: "Stay in control",
    featureControlDescription: "Review each destination before publishing.",
    sectionHow: "02 / HOW IT WORKS",
    processTitle: "Your workflow.<br>Your rules.",
    processDescription: "You decide what goes live. Trelune keeps every step organized.",
    stepOrganize: "Organize",
    stepOrganizeDescription: "Keep ideas, copy, and media together in your library.",
    stepSchedule: "Schedule",
    stepScheduleDescription: "Choose your channels and plan dates in the calendar.",
    stepPublish: "Publish",
    stepPublishDescription: "Review each destination and confirm before publishing.",
    processNote: "The app publishes automatically while it is open. Nothing goes live without your confirmation.",
    downloadTitle: "Your content,<br>at your pace.",
    downloadDescription: "An independent, open-source project for your creative workflow.",
    downloadRequirement: "macOS 14 Sonoma or later",
    independentProject: "AN INDEPENDENT PROJECT.",
    githubLink: "GITHUB ↗",
    footerDisclaimer: "© 2026 TRELUNE. NOT AFFILIATED WITH THE PLATFORMS."
  }
};

const root = document.documentElement;
const themeToggle = document.querySelector(".theme-toggle");
const themeMock = document.querySelector(".theme-mock");
const themeMeta = document.querySelector('meta[name="theme-color"]');
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function readPreference(key, fallback) {
  try { return localStorage.getItem(key) || fallback; }
  catch { return fallback; }
}

function savePreference(key, value) {
  try { localStorage.setItem(key, value); }
  catch { /* The page still works when storage is unavailable. */ }
}

function systemLanguage() {
  const preferred = (navigator.languages && navigator.languages[0]) || navigator.language || "";
  return preferred.toLowerCase().startsWith("pt-br") ? "pt-BR" : "en";
}

function applyLanguage(language) {
  const strings = copy[language];
  root.lang = language;
  document.title = language === "pt-BR" ? "Trelune — seu espaço criativo" : "Trelune — your creative space";
  document.querySelector('meta[name="description"]').content = language === "pt-BR"
    ? "Trelune — planeje, organize e acompanhe suas publicações em um app nativo para macOS."
    : "Trelune — plan, organize, and keep track of your social posts in a native macOS app.";

  document.querySelectorAll("[data-i18n]").forEach((element) => {
    const value = strings[element.dataset.i18n];
    if (value !== undefined) element.textContent = value;
  });
  document.querySelectorAll("[data-i18n-html]").forEach((element) => {
    const value = strings[element.dataset.i18nHtml];
    if (value !== undefined) element.innerHTML = value;
  });
  document.querySelectorAll("[data-i18n-aria]").forEach((element) => {
    const value = strings[element.dataset.i18nAria];
    if (value !== undefined) element.setAttribute("aria-label", value);
  });
  document.querySelectorAll("[data-i18n-title]").forEach((element) => {
    const value = strings[element.dataset.i18nTitle];
    if (value !== undefined) element.title = value;
  });
  document.querySelectorAll("[data-i18n-alt]").forEach((element) => {
    const value = strings[element.dataset.i18nAlt];
    if (value !== undefined) element.alt = value;
  });
}

function applyTheme(theme) {
  root.dataset.theme = theme;
  root.style.colorScheme = theme;
  themeMeta.content = theme === "dark" ? "#101010" : "#fafaf9";
  const locale = root.lang === "pt-BR" ? "pt" : "en";
  themeMock.src = themeMock.dataset[`${locale}${theme === "dark" ? "Dark" : "Light"}Src`];
  const labelKey = theme === "dark" ? "toggleThemeToLight" : "toggleThemeToDark";
  const label = copy[root.lang][labelKey];
  themeToggle.setAttribute("aria-label", label);
  themeToggle.title = label;
  themeToggle.setAttribute("aria-pressed", String(theme === "light"));
}

applyLanguage(systemLanguage());

let theme = readPreference("trelune-theme", "dark");
if (theme !== "light" && theme !== "dark") theme = "dark";
applyTheme(theme);

themeToggle.addEventListener("click", () => {
  theme = theme === "dark" ? "light" : "dark";
  savePreference("trelune-theme", theme);
  applyTheme(theme);
});

window.addEventListener("languagechange", () => {
  applyLanguage(systemLanguage());
  applyTheme(theme);
});

if ("IntersectionObserver" in window && !reduceMotion) {
  const revealObserver = new IntersectionObserver((entries, observer) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("visible");
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.12 });
  document.querySelectorAll(".reveal").forEach((element) => revealObserver.observe(element));
} else {
  document.querySelectorAll(".reveal").forEach((element) => element.classList.add("visible"));
}
