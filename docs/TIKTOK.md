# TikTok no Trelune

Como criar o app do TikTok está em [CONNECTIONS.md](CONNECTIONS.md#tiktok). Este documento descreve o que a integração faz.

## O que está implementado

- Login Desktop no navegador, com PKCE SHA-256 hexadecimal e retorno em loopback.
- Credenciais e tokens no Chaves do macOS, renovação com rotação de refresh token e revogação.
- Consulta da identidade da conta e das opções de publicação direta.
- Envio de vídeos locais por partes, sem carregar o arquivo inteiro na memória.
- Revisão com prévia do vídeo, legenda editável, privacidade e opções de interação retornadas pela API.
- Opções de divulgação comercial e conteúdo gerado por IA.
- Confirmação explícita antes de enviar, progresso, cancelamento da operação local e histórico persistente de status.

O envio como rascunho vai para a caixa de entrada do TikTok; a publicação é concluída no próprio TikTok. A publicação direta exige `video.publish`, e o app consulta as opções da conta antes de cada envio. Fotos usam URLs públicas da hospedagem S3, e o domínio ou prefixo dessas URLs precisa estar verificado no portal do TikTok.

## Uso

1. Abra **Conexões → TikTok**.
2. Informe o Client key e o Client secret do seu app (sandbox ou produção) e salve no Mac.
3. Se quiser publicação direta, marque a opção antes de autorizar.
4. Autorize a conta no navegador. No sandbox, a conta precisa estar em **Target Users**.
5. Use **Enviar vídeo** e revise conta, arquivo e opções. Nada é enviado só por abrir a tela.
6. Acompanhe o histórico. Entrega na caixa de entrada é diferente de publicação confirmada.

Se o macOS pedir acesso ao Chaves depois de uma recompilação, confirme no Mac. Assinar sempre com o mesmo certificado (`CODESIGN_IDENTITY`) evita a pergunta.

## Revisão do TikTok

Para publicar com contas que não estão no sandbox, o TikTok exige revisão do app: site e URLs de termos e privacidade **seus**, domínio verificado, vídeo de demonstração e descrição de uso de cada escopo. Esse processo é feito por quem publica o app, com os próprios dados.

## Referências

- https://developers.tiktok.com/docs/en/login-kit-desktop
- https://developers.tiktok.com/docs/en/oauth-get-a-user-access-token
- https://developers.tiktok.com/docs/en/content-posting-api-reference-upload-video
- https://developers.tiktok.com/docs/en/content-posting-api-reference-direct-post
- https://developers.tiktok.com/docs/en/content-posting-api-media-transfer-guide
- https://developers.tiktok.com/docs/en/content-posting-api-reference-get-video-status
