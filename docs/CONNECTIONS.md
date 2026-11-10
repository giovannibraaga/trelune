# Conectar as redes

O Trelune não traz nenhuma credencial embutida: cada pessoa cria o **próprio app de desenvolvedor** em cada rede e cola as credenciais em **Conexões** dentro do app. Tokens e segredos ficam só no **Chaves do macOS**, separados por serviço (o nome do serviço começa com o `BUNDLE_ID` da sua build). Nada disso vai para o repositório nem para servidores do projeto.

Todas as integrações são opcionais. Conecte só as redes que você usa.

| Rede | O que você precisa criar | Onde |
|---|---|---|
| YouTube | Projeto no Google Cloud + cliente OAuth "App para computador" | [console.cloud.google.com](https://console.cloud.google.com/) |
| Instagram e Facebook | App na Meta com Login do Facebook e Instagram | [developers.facebook.com/apps](https://developers.facebook.com/apps/) |
| Threads | Caso de uso "Acessar a API do Threads" no mesmo app Meta (ou outro) | [developers.facebook.com/apps](https://developers.facebook.com/apps/) |
| TikTok | App com Login Kit e Content Posting API | [developers.tiktok.com](https://developers.tiktok.com/) |
| X | Projeto e app com OAuth 2.0 | [developer.x.com](https://developer.x.com/en/portal/dashboard) |

Instagram, mídia no Threads e fotos no TikTok só aceitam arquivos por **URL HTTPS pública**. Para isso, configure a hospedagem S3 em **Ajustes → Hospedagem** (veja [CLOUD.md](CLOUD.md)).

## YouTube

1. Crie uma conta no [Google Cloud](https://console.cloud.google.com/) (gratuita) e um projeto.
2. Em **APIs e serviços → Biblioteca**, ative **YouTube Data API v3** e, para o gráfico diário, **YouTube Analytics API**.
3. Em **Tela de consentimento OAuth**, escolha *Externo*, preencha nome e e-mail e adicione sua conta Google em **Usuários de teste**.
4. Em **Credenciais → Criar credenciais → ID do cliente OAuth**, escolha **App para computador** e baixe o JSON.
5. No Trelune: **Conexões → YouTube → Importar JSON do Google** e depois **Autorizar YouTube**.

Escopos pedidos: `youtube.readonly`, `youtube.upload`, `yt-analytics.readonly`. O login usa PKCE e retorno local (loopback); nenhum endereço de retorno precisa ser cadastrado.

Referências: [OAuth para apps instalados](https://developers.google.com/identity/protocols/oauth2/native-app), [videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert).

## Instagram e Facebook (Meta)

1. Crie uma conta em [Meta for Developers](https://developers.facebook.com/) e, em **Meus apps → Criar app**, escolha os casos de uso de **Páginas do Facebook** e **Instagram**.
2. Em **Configurações → Básico**, copie o **ID do app** e a **Chave secreta do app**.
3. No Trelune: **Conexões → Instagram/Facebook**, cole os dois valores e clique em **Salvar no Chaves do macOS**.
4. Conecte de uma das formas:
   - **Token (recomendado):** abra o [Graph API Explorer](https://developers.facebook.com/tools/explorer/), escolha o seu app, gere um token de usuário com as permissões que o Trelune lista (botão *Copiar permissões*) e cole no app.
   - **Login pelo navegador:** retorno em `http://localhost:49682/oauth/callback`. Se a Meta mostrar "Can't load URL", adicione `localhost` em *Domínios do app* e o endereço em *URIs de redirecionamento do OAuth válidos*.

Requisitos da Meta:

- O Instagram precisa ser conta **Business ou Creator** vinculada a uma Página que você administra.
- O Facebook publica em **Páginas**, não em perfis pessoais. Adicione `pages_manage_posts` ao caso de uso *Manage everything on your Page*.
- Em modo de desenvolvimento, só contas com papel no app podem autorizar. Para outras pessoas, a Meta exige acesso avançado e revisão.

Referências: [Instagram API](https://developers.facebook.com/docs/instagram-platform), [Pages API](https://developers.facebook.com/docs/pages-api).

## Threads

A API do Threads só aceita retorno OAuth em HTTPS, então o Trelune usa um token de usuário gerado no painel da Meta:

1. No seu app Meta, adicione o caso de uso **Acessar a API do Threads**.
2. Em **Funções do app → Threads Tester**, convide a sua conta e aceite em threads.com → *Configurações → Mais configurações → Permissões de sites → Convites*.
3. Em **Casos de uso → Threads → Configurações → Gerador de token de usuário**, gere um token com `threads_basic`, `threads_content_publish` e `threads_manage_insights`.
4. No Trelune: **Conexões → Threads**, cole o token. O app renova o token antes de expirar.

Limites aplicados antes de publicar: 500 caracteres e 5 links; imagens JPG/PNG até 8 MB; vídeo MP4/MOV até 5 min e 1 GB; carrossel de 2 a 20 itens.

## TikTok

1. Crie uma conta em [TikTok for Developers](https://developers.tiktok.com/) e um app com plataforma **Desktop**.
2. Adicione os produtos **Login Kit** e **Content Posting API**. Callback: `http://127.0.0.1:*/oauth/callback`.
3. Escopos: `user.info.basic` e `video.upload`; para publicação direta, `video.publish` (e ative *Direct Post*). Para métricas, `user.info.stats` e `video.list`.
4. Para testar antes da revisão do TikTok, use o **Sandbox** do app e adicione sua conta em **Target Users**.
5. No Trelune: **Conexões → TikTok**, cole o *Client key* e o *Client secret* e clique em **Autorizar TikTok**.

Detalhes do fluxo em [TIKTOK.md](TIKTOK.md). Apps não auditados pelo TikTok têm restrições de visibilidade.

## X

1. Crie uma conta em [developer.x.com](https://developer.x.com/en/portal/dashboard), aceite o *Developer Agreement* e crie um projeto e um app.
2. Em **User authentication settings**: OAuth 2.0, permissão **Read and write**, tipo **Native App** (sem segredo) ou **Web App** (informe o Client Secret).
3. Callback URI: `http://127.0.0.1:49683/oauth/callback`.
4. No Trelune: **Conexões → X**, cole o Client ID (e o Client Secret, se houver) e clique em **Autorizar X**.

Escopos: `tweet.read tweet.write users.read media.write offline.access`. O plano de acesso da API precisa permitir escrita. Limites: 280 caracteres contados como o X conta (link = 23, emoji = 2); até 4 imagens de 5 MB ou um GIF; vídeo não é enviado.

## Limites gerais

- Sem a publicação pela nuvem, o próprio app publica no horário enquanto estiver aberto (a janela pode estar fechada; o ícone fica na barra de menus). Com ela ligada, a Lambda da **sua** conta AWS publica com o Mac desligado — veja [CLOUD.md](CLOUD.md).
- No TikTok, o envio agendado vai para a caixa de entrada do app; a publicação é concluída no TikTok.
- As métricas refletem apenas os campos que cada API autoriza retornar.
- Envios imediatos sempre pedem confirmação; agendamentos são confirmados ao agendar.
- Se uma credencial vazar, revogue-a no portal da rede e gere outra.
