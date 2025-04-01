# WebRTC Camera Feed Replacement System

## Visão Geral do Projeto

Este projeto implementa um sistema WebRTC otimizado para substituir transparentemente o feed da câmera nativa do iOS. O sistema consiste em um servidor de sinalização WebRTC, uma interface web para transmissão, e um tweak iOS que primeiro exibe o stream em uma janela flutuante (para testes) e posteriormente substituirá diretamente o feed da câmera nativa.

A meta final é uma substituição completamente transparente, onde qualquer aplicativo que use a câmera nativa (fotos, vídeos, apps de terceiros) receberá o stream WebRTC como se fosse o feed original da câmera, sem necessidade de modificações adicionais.

## Estado Atual do Código

| Arquivo | Descrição | Estado Atual |
|---------|-----------|--------|
| `server.js` | Servidor de sinalização WebRTC | ✅ Funcional, otimizado para formatos iOS |
| `index.html` | Interface web de transmissão | ✅ Funcional, otimizado para codecs iOS |
| `Tweak.xm` | Ponto de entrada do tweak | ✅ Funcional, reorganizado |
| `FloatingWindow.h/m` | Interface de preview | ✅ Funcional, com suporte para informações de formato |
| `WebRTCManager.h/m` | Gerenciamento de conexão | ✅ Funcional, necessita otimizações específicas |
| `WebRTCFrameConverter.h/m` | Processamento de frames | ✅ Funcional, necessita melhorias de gerenciamento de recursos |
| `logger.h/m` | Sistema de logging | ✅ Funcional, bem implementado |
| `implemetacaoSubstituicao.txt` | Referência para substituição | 🔄 Necessita refinamentos antes da implementação |

## Estado Atual do Desenvolvimento

O projeto encontra-se atualmente na **fase final de preparação antes da substituição direta do feed da câmera**. A implementação de visualização do stream WebRTC em uma janela flutuante está funcional e otimizada para formatos nativos do iOS.

### Pontos Fortes da Implementação Atual:

1. **Compatibilidade otimizada com iOS:**
   - Suporte completo para formatos YUV (420f, 420v) e BGRA
   - Priorização de codecs compatíveis com iOS (H.264 com perfil baseline)
   - Transmissão em alta qualidade (até 4K/60fps) com adaptação automática

2. **Sistema modular bem estruturado:**
   - Separação clara entre gerenciamento WebRTC e conversão de frames
   - Interface flutuante com diagnósticos visuais
   - Sistema de logging extensivo

3. **Mecanismos de resiliência:**
   - Reconexão automática após falhas
   - Adaptação dinâmica à qualidade da rede
   - Monitoramento de performance

## Plano de Ação Antes da Substituição

Antes de avançar para a fase de substituição direta do feed da câmera, é necessário realizar as seguintes otimizações:

### Etapa 1: Correção de Gerenciamento de Recursos (Alta Prioridade) ✅

- [✅] Revisar e corrigir liberação de memória para CMSampleBuffer
- [✅] Verificar bloqueios/desbloqueios corretos de CVPixelBuffer
- [✅] Implementar rastreamento de recursos para evitar vazamentos
- [✅] Otimizar sistema de cache de frames

### Etapa 2: Sincronização e Precisão de Timing (Alta Prioridade) ✅

- [✅] Implementar sincronização precisa de timestamps com relógio do sistema
- [✅] Configurar corretamente CMTimingInfo para preservar timing original
- [✅] Adicionar suporte adequado para frames droppados

### Etapa 3: Otimizações de Performance (Média Prioridade) ✅

- [✅] Acelerar conversão de formatos nativos do iOS (especialmente YUV 4:2:0)
- [✅] Maximizar uso de aceleração de hardware
- [✅] Otimizar escalonamento de resolução e taxa de frames

### Etapa 4: Preparação para Substituição (Alta Prioridade)

- [ ] Refinar código de hook para AVCaptureSession
- [ ] Melhorar detecção e manipulação de delegates de câmera
- [ ] Implementar preservação de metadados importantes (exposição, balance de branco)
- [ ] Adicionar simulação de recursos como flash e zoom

### Etapa 5: Sistema de Diagnóstico Avançado (Média Prioridade)

- [ ] Implementar logging específico para processo de substituição
- [ ] Adicionar contadores de frames por fonte (original vs. substituído)
- [ ] Criar visualizadores de diagnóstico em tempo real

### Etapa 6: Testes Finais (Média Prioridade)

- [ ] Adicionar chaves de configuração para alternar modos
- [ ] Testar com múltiplos aplicativos de câmera populares
- [ ] Documentar comportamentos e compatibilidade por aplicativo

## Requisitos de Compatibilidade Identificados

Com base em análise de diagnóstico da câmera iOS, identificamos os seguintes requisitos críticos para a substituição transparente:

### 1. Formatos de Pixel
A câmera iOS utiliza principalmente três formatos:
- `420f` (YUV 4:2:0 full-range) - **Formato principal e prioritário**
- `420v` (YUV 4:2:0 video-range)
- `BGRA` (32-bit BGRA)

### 2. Resoluções
- Câmera traseira: 4032x3024 (12MP)
- Preview de câmera: 1334x750
- Renderização final: Adaptada para dimensões da tela (ex: 375x667)

### 3. Classes Principais de iOS para Hook
- `AVCaptureSession`: Controla toda a sessão de captura
- `AVCaptureVideoDataOutput`: Gerencia saída de vídeo e delegates
- `AVCaptureConnection`: Gerencia orientação e espelhamento

### 4. Métodos Críticos para Interceptação
- `AVCaptureSession startRunning`
- `AVCaptureVideoDataOutput setSampleBufferDelegate:`
- `AVCaptureConnection setVideoOrientation:`
- `AVCaptureConnection setVideoMirrored:`

## Arquitetura para Substituição Direta da Câmera

Para substituir diretamente o feed da câmera, permitindo funcionamento transparente com todos os apps, implementaremos:

### 1. Hook Primário em AVCaptureSession
Este é o ponto mais fundamental para interceptação, permitindo substituir o feed no nível mais básico:
```objective-c
%hook AVCaptureSession

- (void)startRunning {
    // Configurar injeção de feed antes da execução original
    %orig;
    // Ativar substituição após inicialização original
}

%end
```

### 2. Gerenciamento de Delegates e Outputs
Para garantir que o feed substituto seja entregue a todos os delegates:
```objective-c
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    // Registrar o delegate original
    // Configurar interceptação de frames
    %orig;
}

%end
```

### 3. Sistema de Injeção de Frames Adaptativo
```objective-c
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)originalBuffer fromConnection:(AVCaptureConnection *)connection {
    // Se substituição ativa, substituir buffer com feed WebRTC
    // Se não, passar buffer original
    
    // Adaptar formato, resolução e orientação
    // Encaminhar para delegate original
}
```

## Uso Atual (Fase de Preview)

### Iniciar Servidor
```bash
node server.js
```

### Transmitir Vídeo
1. Acesse `http://<ip_do_servidor>:8080` em um navegador
2. Selecione a qualidade e a fonte de vídeo
3. Inicie a transmissão

### Visualizar no dispositivo iOS
1. A janela flutuante aparecerá no iOS
2. Toque em "Ativar Preview" para visualizar o stream
3. Use gestos para mover e interagir com a janela
4. Observe as informações de formato de pixel e processamento para diagnóstico

## Próximos Passos

Após a conclusão das otimizações listadas no Plano de Ação, o projeto avançará para a fase de implementação da substituição direta do feed da câmera, onde o stream WebRTC será injetado diretamente na cadeia de processamento de vídeo do iOS, permitindo que qualquer aplicativo que use a câmera receba o stream como se fosse o feed da câmera real.

---

Este documento representa o estado atual do projeto e o plano de otimizações necessárias antes da implementação da substituição direta do feed da câmera nativa do iOS.
