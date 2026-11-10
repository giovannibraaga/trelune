# Trelune — site de apresentação

Landing page estática para apresentar o Trelune, um app nativo para macOS que ajuda a planejar, organizar e acompanhar publicações para redes sociais.

O site oferece temas claro e escuro, com preferência salva no navegador. O idioma acompanha automaticamente o idioma preferido do sistema: usa PT-BR quando ele é português brasileiro e inglês nos demais casos.

## Pré-visualizar no Mac

Não é necessário instalar dependências nem configurar variáveis de ambiente. Com Python 3 instalado, entre nesta pasta e rode:

```bash
python3 -m http.server 4173
```

Abra <http://localhost:4173> no navegador. Para interromper o servidor, use `Ctrl+C` no Terminal.

## Conteúdo do site

- `index.html`: conteúdo e estrutura da página.
- `styles.css`: layout responsivo e temas monocromáticos claro e escuro.
- `script.js`: alternância de tema, idioma e animações leves da página.
- `assets/`: marca monocromática e variações dos mocks do Figma.

As imagens de demonstração são baseadas nos frames claro e escuro do Figma, com variações em português brasileiro e inglês. O perfil pessoal foi substituído por “Luna Studio”; os números e demais dados são ilustrativos. Nenhuma conta foi conectada e nenhum dado ou credencial real é usado pelo site.

## Publicar

Publique o conteúdo desta pasta em qualquer hospedagem de site estático. Para GitHub Pages, configure a pasta `/website` como fonte de publicação se o repositório permitir, ou publique estes arquivos na raiz de um repositório dedicado ao site. Use HTTPS.

Os botões de download apontam para a página de Releases do repositório. Publique uma release com o app macOS antes de divulgar o link; sem uma release pública, ainda não há build para baixar.

## Personalizar o download

Antes de publicar, confira no `index.html` o link de Releases usado pelos botões de download e troque-o pelo endereço definitivo, caso a distribuição do app passe a usar outro repositório ou página.
