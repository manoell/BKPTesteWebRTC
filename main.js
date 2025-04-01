// Elementos da página
const startButton = document.getElementById('startButton');
const stopButton = document.getElementById('stopButton');
const videoSource = document.getElementById('videoSource');
const videoQuality = document.getElementById('videoQuality');
const frameRate = document.getElementById('frameRate');
const localVideo = document.getElementById('localVideo');
const roomIdInput = document.getElementById('roomId');
const statusDiv = document.getElementById('status');
const videoStats = document.getElementById('videoStats');
const connectionStats = document.getElementById('connectionStats');
const statsPanel = document.getElementById('statsPanel');
const advancedToggle = document.getElementById('advancedToggle');
const advancedSection = document.getElementById('advancedSection');
const videoCodec = document.getElementById('videoCodec');
const h264Profile = document.getElementById('h264Profile');
const pixelFormat = document.getElementById('pixelFormat');
const iosOptimize = document.getElementById('iosOptimize');
const connectionInfo = document.getElementById('connectionInfo');

// Toggle para configurações avançadas
advancedToggle.addEventListener('click', () => {
    advancedSection.classList.toggle('hidden');
    advancedToggle.querySelector('span:last-child').textContent = 
        advancedSection.classList.contains('hidden') ? '▼' : '▲';
});

// Variáveis WebRTC
let localStream;
let peerConnection;
let ws;
let statsInterval;
let reconnectTimeout;
let reconnectAttempts = 0;
const MAX_RECONNECT_ATTEMPTS = 5;
const serverUrl = location.hostname === 'localhost' || location.hostname === '127.0.0.1'
    ? `ws://${location.host}`
    : `ws://${location.hostname}:8080`;

// Para controle de keep-alive
let keepAliveInterval;
let lastPongReceived = 0;
let connectionCheckInterval;
let offerCreatedForRoom = {};

// Mapeamento de qualidades de vídeo
const videoQualities = {
    '720p': { width: 1280, height: 720 },
    '1080p': { width: 1920, height: 1080 },
    '1440p': { width: 2560, height: 1440 },
    '2160p': { width: 3840, height: 2160 }
};

// Inicialização
async function initialize() {
    try {
        updateStatus('Inicializando câmeras...', 'connecting');

        // Verificar suporte a getUserMedia
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            throw new Error('Seu navegador não suporta acesso à câmera (getUserMedia)');
        }

        // Listar dispositivos de vídeo disponíveis
        const devices = await navigator.mediaDevices.enumerateDevices();
        const videoDevices = devices.filter(device => device.kind === 'videoinput');

        // Adicionar opções ao select
        videoSource.innerHTML = '';
        videoDevices.forEach(device => {
            const option = document.createElement('option');
            option.value = device.deviceId;
            option.text = device.label || `Câmera ${videoSource.length + 1}`;
            videoSource.appendChild(option);
        });

        // Se não houver rótulos, solicitar permissão de câmera e retornar
        if (videoDevices.length > 0 && !videoDevices[0].label) {
            try {
                // Solicitar permissão e mostrar preview inicial
                await getLocalMediaStream();
                
                // Atualizar lista de dispositivos com os rótulos
                const updatedDevices = await navigator.mediaDevices.enumerateDevices();
                const updatedVideoDevices = updatedDevices.filter(device => device.kind === 'videoinput');
                
                // Limpar e repopular o select
                videoSource.innerHTML = '';
                updatedVideoDevices.forEach(device => {
                    const option = document.createElement('option');
                    option.value = device.deviceId;
                    option.text = device.label || `Câmera ${videoSource.length + 1}`;
                    videoSource.appendChild(option);
                });
                
                // Configurar a câmera preferencial
                const preferredCameras = updatedVideoDevices.filter(device =>
                    device.label.toLowerCase().includes('hd') ||
                    device.label.toLowerCase().includes('4k') ||
                    device.label.toLowerCase().includes('pro')
                );

                if (preferredCameras.length > 0) {
                    videoSource.value = preferredCameras[0].deviceId;
                }
                
                updateStatus('Pronto para transmitir', 'offline');
            } catch (err) {
                console.error('Erro ao acessar câmera durante inicialização:', err);
                updateStatus('Erro ao acessar câmera', 'offline');
            }
            return;
        }

        if (videoDevices.length === 0) {
            updateStatus('Nenhuma câmera encontrada', 'offline');
        } else {
            updateStatus('Pronto para transmitir', 'offline');
            
            // Configurar câmera preferencial
            const preferredCameras = videoDevices.filter(device =>
                device.label.toLowerCase().includes('hd') ||
                device.label.toLowerCase().includes('4k') ||
                device.label.toLowerCase().includes('pro')
            );

            if (preferredCameras.length > 0) {
                videoSource.value = preferredCameras[0].deviceId;
            }
        }
    } catch (error) {
        console.error('Erro ao inicializar:', error);
        updateStatus(`Erro: ${error.message}`, 'offline');
    }
    
    // Iniciar verificação de saúde da conexão
    startConnectionHealthCheck();
}

// Obter stream local com qualidade configurada
async function getLocalMediaStream() {
    try {
        if (localStream) {
            localStream.getTracks().forEach(track => track.stop());
        }

        // Obter qualidade selecionada
        const quality = videoQualities[videoQuality.value];
        const fps = parseInt(frameRate.value);

        console.log(`Configurando vídeo: ${quality.width}x${quality.height} a ${fps}fps`);

        const constraints = {
            audio: false,
            video: {
                deviceId: videoSource.value ? { exact: videoSource.value } : undefined,
                width: { ideal: quality.width },
                height: { ideal: quality.height },
                frameRate: { ideal: fps }
            }
        };

        localStream = await navigator.mediaDevices.getUserMedia(constraints);

        // Log das configurações reais obtidas
        const videoTrack = localStream.getVideoTracks()[0];
        if (videoTrack) {
            const settings = videoTrack.getSettings();
            console.log('Configurações reais do vídeo:', settings);
            videoStats.innerHTML = `Fonte: ${videoTrack.label}<br>` +
                                `Resolução: ${settings.width}x${settings.height}<br>` +
                                `FPS: ${settings.frameRate || 'desconhecido'}<br>` +
                                `Aspect Ratio: ${(settings.width/settings.height).toFixed(2)}`;
            statsPanel.classList.remove('hidden');
        }

        localVideo.srcObject = localStream;
        return localStream;
    } catch (error) {
        console.error('Erro ao acessar câmera:', error);
        updateStatus(`Erro ao acessar câmera: ${error.message}`, 'offline');
        throw error;
    }
}

// Configurar conexão WebRTC
async function setupPeerConnection() {
    console.log("Criando nova conexão peer, garantindo que recursos antigos foram liberados");
    
    // Verificação de segurança para garantir que conexões anteriores foram limpas
    if (peerConnection) {
        console.warn("Conexão peer anterior ainda existe, fechando forçadamente");
        try {
            peerConnection.close();
        } catch (e) {
            console.error("Erro ao fechar conexão anterior:", e);
        }
        peerConnection = null;
        
        // Esperar um pouco para garantir liberação de recursos
        await new Promise(resolve => setTimeout(resolve, 1000));
    }

    // Configuração altamente otimizada para redes locais
    const config = {
        iceServers: [
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' },
            { urls: 'stun:stun2.l.google.com:19302' }
        ],
        iceTransportPolicy: 'all',
        bundlePolicy: 'max-bundle',
        rtcpMuxPolicy: 'require',
        sdpSemantics: 'unified-plan',
        // Crucial: habilitar TCP para melhor desempenho em rede local
        iceTransportPolicy: 'all',
        // Reduzir pool de candidatos para redes locais
        iceCandidatePoolSize: 0
    };

    peerConnection = new RTCPeerConnection(config);

    // Adicionar stream de vídeo
    if (localStream) {
        console.log("Adicionando tracks do stream local");
        localStream.getTracks().forEach(track => {
            console.log(`Adicionando track: ${track.kind}`);
            peerConnection.addTrack(track, localStream);
        });
    } else {
        console.warn("Sem stream local disponível para adicionar à conexão peer");
    }

    // Configurar timeout de conexão ICE mais generoso
    let iceConnectionTimeout = setTimeout(() => {
        if (peerConnection && peerConnection.iceConnectionState !== 'connected' && 
            peerConnection.iceConnectionState !== 'completed') {
            console.warn("Timeout de conexão ICE - reiniciando processo");
            resetVideoStream();
        }
    }, 30000); // 30 segundos para estabelecer conexão ICE

    // Configurar eventos com tratamento de erro aprimorado
    peerConnection.onicecandidate = event => {
        try {
            if (event.candidate) {
                console.log(`Enviando candidato ICE: ${event.candidate.candidate.substring(0, 50)}...`);
                
                sendMessage({
                    type: 'ice-candidate',
                    candidate: event.candidate.candidate,
                    sdpMid: event.candidate.sdpMid,
                    sdpMLineIndex: event.candidate.sdpMLineIndex,
                    roomId: roomIdInput.value
                });
            } else {
                console.log("Coleta de candidatos ICE completa");
                // Garantir que a negociação continue mesmo sem candidatos
                setTimeout(() => {
                    if (peerConnection.iceConnectionState === 'new' || 
                        peerConnection.iceConnectionState === 'checking') {
                        console.log("Forçando continuação da negociação após coleta de candidatos");
                        // Criar nova oferta para forçar negociação
                        if (peerConnection.signalingState === 'stable') {
                            createAndSendOffer(true);
                        }
                    }
                }, 5000);
            }
        } catch (e) {
            console.error("Erro no tratamento de candidato ICE:", e);
        }
    };

    peerConnection.oniceconnectionstatechange = () => {
        console.log('ICE State:', peerConnection.iceConnectionState);
        connectionStats.innerHTML = `ICE State: ${peerConnection.iceConnectionState}`;
        connectionInfo.textContent = `Status da conexão: ${peerConnection.iceConnectionState}`;
        
        // Limpar timeout se conectado
        if (peerConnection.iceConnectionState === 'connected' || 
            peerConnection.iceConnectionState === 'completed') {
            clearTimeout(iceConnectionTimeout);
        }
        
        // Tratamento de problemas de conexão
        if (peerConnection.iceConnectionState === 'failed' ||
            peerConnection.iceConnectionState === 'disconnected') {
            console.error('Problema na conexão ICE:', peerConnection.iceConnectionState);
            
            // Se estiver em estado 'failed', forçar reconexão imediatamente
            if (peerConnection.iceConnectionState === 'failed') {
                console.log("Estado 'failed' detectado, forçando reconexão");
                resetVideoStream();
            } 
            // Se 'disconnected', dar chance de recuperação automática
            else if (peerConnection.iceConnectionState === 'disconnected') {
                console.log("Estado 'disconnected', dando chance de recuperação");
                setTimeout(() => {
                    if (peerConnection && peerConnection.iceConnectionState === 'disconnected') {
                        console.log("Ainda 'disconnected' após espera, forçando reconexão");
                        resetVideoStream();
                    }
                }, 10000); // Esperar 10s para ver se recupera sozinho
            }
        }
    };

    peerConnection.onicecandidateerror = (event) => {
        console.warn('Erro no candidato ICE:', event);
    };

    // Monitor de estatísticas muito mais agressivo
    setupAdaptiveQuality();
    
    return peerConnection;
}

function setupAdaptiveQuality() {
    if (!peerConnection) return;
    
    let lastQualityCheckTime = Date.now();
    let connectionIssues = 0;
    let lastFrameCount = 0;
    let freezeDetectionCount = 0;
    
    // Monitor de qualidade a cada 3 segundos
    const qualityInterval = setInterval(async () => {
        if (!peerConnection || !startButton.disabled) {
            clearInterval(qualityInterval);
            return;
        }
        
        try {
            const stats = await peerConnection.getStats();
            let packetLoss = 0;
            let jitter = 0;
            let roundTripTime = 0;
            let framesReceived = 0;
            let framesDropped = 0;
            
            stats.forEach(stat => {
                // Monitor de qualidade da conexão
                if (stat.type === 'outbound-rtp' && stat.kind === 'video') {
                    packetLoss = stat.packetsLost || 0;
                    framesReceived = stat.framesEncoded || 0;
                    framesDropped = stat.framesDropped || 0;
                } else if (stat.type === 'candidate-pair' && stat.state === 'succeeded') {
                    roundTripTime = stat.currentRoundTripTime || 0;
                    jitter = stat.jitter || 0;
                }
            });
            
            const now = Date.now();
            // Detecção de congelamento (se framesReceived não está aumentando)
            if (lastFrameCount > 0 && framesReceived === lastFrameCount) {
                freezeDetectionCount++;
                console.warn(`Possível congelamento de vídeo detectado (${freezeDetectionCount}/3)`);
                
                if (freezeDetectionCount >= 3) {
                    console.log("Congelamento de vídeo confirmado, tentando reiniciar stream");
                    resetVideoStream();
                    freezeDetectionCount = 0;
                }
            } else {
                // Reset do contador se está recebendo frames
                freezeDetectionCount = 0;
            }
            
            lastFrameCount = framesReceived;
            
            // Se temos problemas de conexão
            if (packetLoss > 10 || jitter > 0.05 || roundTripTime > 0.3 || framesDropped > 5) {
                connectionIssues++;
                console.warn(`Problemas de conexão detectados: perda=${packetLoss}, jitter=${jitter}, RTT=${roundTripTime}, framesDropped=${framesDropped}`);
                
                // Se persistirem, tentar reconectar
                if (connectionIssues >= 3 && (now - lastQualityCheckTime > 15000)) {
                    console.log("Problemas persistentes de conexão, tentando reiniciar conexão");
                    resetVideoStream();
                    lastQualityCheckTime = now;
                    connectionIssues = 0;
                }
            } else {
                // Resetar contador se não há problemas
                connectionIssues = Math.max(0, connectionIssues - 1);
            }
        } catch (e) {
            console.error("Erro ao verificar qualidade da conexão:", e);
        }
    }, 3000); // Reduzido de 5s para 3s para detecção mais rápida
}

// Iniciar monitoramento de estatísticas
function startStatsMonitor() {
    if (statsInterval) {
        clearInterval(statsInterval);
    }

    statsInterval = setInterval(async () => {
        if (!peerConnection) return;

        const stats = await peerConnection.getStats();
        let outboundRtpStats;

        stats.forEach(stat => {
            if (stat.type === 'outbound-rtp' && stat.kind === 'video') {
                outboundRtpStats = stat;
            }
        });

        if (outboundRtpStats) {
            const { bytesSent, packetsSent, framesSent, framesPerSecond } = outboundRtpStats;

            connectionStats.innerHTML = `ICE State: ${peerConnection.iceConnectionState}<br>` +
                                   `Dados enviados: ${formatBytes(bytesSent)}<br>` +
                                   `Pacotes enviados: ${packetsSent}<br>` +
                                   `Frames enviados: ${framesSent}<br>` +
                                   `FPS atual: ${framesPerSecond || 'desconhecido'}`;
        }
    }, 1000);
}

// Formatar bytes para exibição
function formatBytes(bytes, decimals = 2) {
    if (bytes === 0) return '0 Bytes';

    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));

    return parseFloat((bytes / Math.pow(k, i)).toFixed(decimals)) + ' ' + sizes[i];
}

// Iniciar keep-alive timer
function startKeepAliveTimer() {
    // Limpar intervalo existente, se houver
    if (keepAliveInterval) {
        clearInterval(keepAliveInterval);
        keepAliveInterval = null;
    }
    
    // Enviar ping a cada 5 segundos
    keepAliveInterval = setInterval(() => {
        if (ws && ws.readyState === WebSocket.OPEN) {
            // Verificar se não recebemos pong há muito tempo
            const now = Date.now();
            if (lastPongReceived > 0 && now - lastPongReceived > 20000) {
                console.warn("Conexão inativa há mais de 20s, tentando reconectar...");
                
                // Fechar conexão existente
                try {
                    const oldWs = ws;
                    ws = null;
                    oldWs.close();
                } catch (e) {
                    console.error("Erro ao fechar WebSocket:", e);
                }
                
                // Reconectar após breve delay
                setTimeout(() => {
                    if (startButton.disabled) { // Só reconecta se streaming estiver ativo
                        connectWebSocket();
                    }
                }, 500);
                
                return;
            }
            
            // Enviar ping via WebSocket nativo
            try {
                ws.ping();
            } catch(e) {
                console.warn("Erro ao enviar ping nativo:", e);
            }
            
            // Enviar mensagem de ping JSON
            sendMessage({
                type: 'ping',
                timestamp: Date.now(),
                roomId: roomIdInput.value
            });
            console.log("Enviando keep-alive ping para o servidor");
        } else if (startButton.disabled && (!ws || ws.readyState !== WebSocket.OPEN)) {
            // Se o streaming está ativo mas WebSocket não está aberto, reconectar
            console.warn("WebSocket não está conectado e streaming ativo, reconectando...");
            connectWebSocket();
        }
    }, 5000);
    
    // Adicionar ao runloop principal para garantir execução
    if (keepAliveInterval) {
        window.addEventListener('beforeunload', () => {
            clearInterval(keepAliveInterval);
        });
    }
}

// Parar keep-alive timer
function stopKeepAliveTimer() {
    if (keepAliveInterval) {
        clearInterval(keepAliveInterval);
        keepAliveInterval = null;
    }
}

// Verificar saúde da conexão periodicamente
function startConnectionHealthCheck() {
    if (connectionCheckInterval) {
        clearInterval(connectionCheckInterval);
    }
    
    // Verificar a cada 5 segundos (reduzido de 15 segundos)
    connectionCheckInterval = setInterval(() => {
        if (ws && ws.readyState === WebSocket.OPEN && startButton.disabled) {
            const now = Date.now();
            // Reduzido de 30s para 15s para maior agressividade na detecção
            if (lastPongReceived > 0 && now - lastPongReceived > 15000) {
                console.warn("Possível conexão zumbi detectada - sem resposta por 15s");
                updateStatus('Reconectando (conexão inativa)...', 'connecting');
                
                // Forçar reconexão
                ws.close();
                // Reconectar imediatamente com menos espera
                setTimeout(() => {
                    if (startButton.disabled) {
                        connectWebSocket();
                    }
                }, 500); // Reduzido de 1000ms para 500ms
            }
        }
    }, 5000); // Reduzido de 15s para 5s
}

// Adicione esta função no arquivo main.js
async function resetVideoStream() {
    console.log("Resetando stream de vídeo após problemas de conexão");
    
    try {
        // 1. Fechar a conexão peer existente
        if (peerConnection) {
            try {
                // Remover all tracks
                const senders = peerConnection.getSenders();
                for (const sender of senders) {
                    try {
                        peerConnection.removeTrack(sender);
                    } catch (e) {
                        console.warn("Erro ao remover track:", e);
                    }
                }
                
                // Fechar a conexão
                peerConnection.close();
                peerConnection = null;
            } catch (e) {
                console.error("Erro ao fechar conexão peer:", e);
            }
        }
        
        // 2. Limpar WebSocket atual e reconectar
        if (ws) {
            try {
                const oldWs = ws;
                ws = null;
                oldWs.close();
            } catch (e) {
                console.warn("Erro ao fechar WebSocket:", e);
            }
        }
        
        // Esperar um pouco para garantir limpeza
        await new Promise(resolve => setTimeout(resolve, 1000));
        
        // 3. Restablecer stream local se necessário
        if (localStream) {
            try {
                // Opcionalmente, também podemos reiniciar o stream local
                const tracks = localStream.getTracks();
                tracks.forEach(track => track.stop());
                
                // Obter stream de novo
                await getLocalMediaStream();
            } catch (e) {
                console.error("Erro ao reiniciar stream local:", e);
            }
        }
        
        // 4. Recriar a conexão peer
        await setupPeerConnection();
        
        // 5. Reconectar ao servidor
        connectWebSocket();
        
        connectionInfo.textContent = 'Status da conexão: Reconectado, aguardando negociação';
    } catch (e) {
        console.error("Erro ao resetar stream de vídeo:", e);
    }
}

// Conectar ao servidor WebSocket com reconexão automática
function connectWebSocket() {
    if (ws && ws.readyState !== WebSocket.CLOSED && ws.readyState !== WebSocket.CLOSING) {
        console.log('WebSocket já está conectado ou conectando');
        return;
    }

    console.log(`Conectando ao WebSocket: ${serverUrl}`);
    
    ws = new WebSocket(serverUrl);

    ws.onopen = () => {
        console.log('WebSocket conectado');
        // Resetar contador de reconexão quando conectado com sucesso
        reconnectAttempts = 0;
        lastPongReceived = Date.now(); // Inicializar timestamp de pong
        
        // Enviar informações sobre o tipo de dispositivo e otimizações
        const deviceInfo = {
            type: 'join',
            roomId: roomIdInput.value,
            deviceType: 'web',
            capabilities: {
                h264Supported: true,
                preferIOS: iosOptimize.checked,
                preferredCodec: videoCodec.value,
                preferredH264Profile: h264Profile.value,
                preferredPixelFormat: pixelFormat.value
            }
        };
        
        ws.send(JSON.stringify(deviceInfo));
        updateStatus('Conectado ao servidor', 'online');
        
        // Iniciar keep-alive
        startKeepAliveTimer();
    };

    ws.onclose = (event) => {
        console.log(`WebSocket desconectado (código: ${event.code}, razão: ${event.reason})`);
        updateStatus('Desconectado do servidor', 'offline');
        
        // Parar o keep-alive quando desconectado
        stopKeepAliveTimer();

        // Tentar reconectar após um delay, a menos que a transmissão tenha sido explicitamente parada
        if (startButton.disabled && !stopButton.disabled) {
            const delay = Math.min(1000 * Math.pow(1.5, reconnectAttempts), 10000); // Backoff exponencial com máximo de 10s
            console.log(`Tentando reconectar em ${delay/1000}s (tentativa ${reconnectAttempts + 1}/${MAX_RECONNECT_ATTEMPTS})`);
            
            if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
                reconnectAttempts++;
                updateStatus(`Reconectando em ${Math.round(delay/1000)}s... (${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})`, 'connecting');
                
                clearTimeout(reconnectTimeout);
                reconnectTimeout = setTimeout(() => {
                    connectWebSocket();
                }, delay);
            } else {
                updateStatus('Falha ao reconectar. Tente novamente manualmente.', 'offline');
                // Resetar a interface para permitir nova tentativa
                stopStreaming(false);
            }
        }
    };

    ws.onerror = (error) => {
        console.error('WebSocket erro:', error);
        updateStatus('Erro de conexão', 'offline');
        connectionInfo.textContent = 'Status da conexão: Erro';
    };

    ws.onmessage = (event) => {
        const message = JSON.parse(event.data);
        handleMessage(message);
    };
}

// Enviar mensagem para o servidor
function sendMessage(message) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(message));
    } else {
        console.warn('Não foi possível enviar mensagem, WebSocket não está conectado');
        connectionInfo.textContent = 'Status da conexão: Não conectado';
    }
}

// Processar mensagens recebidas
async function handleMessage(message) {
    console.log('Mensagem recebida:', message.type);

    switch (message.type) {
        case 'user-joined':
			console.log('Dispositivo conectado:', message.deviceType || 'desconhecido');
			
			// Criar oferta apenas se ainda não tivermos criado uma para esta sala,
			// se for um dispositivo iOS, ou após reconexão (para restaurar o streaming)
			const roomId = roomIdInput.value;
			const isIOS = message.deviceType === 'ios';
			
			// Verificar se este é um evento de reconexão do dispositivo iOS
			const isReconnection = reconnectAttempts > 0 || offerCreatedForRoom[roomId];
			
			if (!offerCreatedForRoom[roomId] || isIOS || isReconnection) {
				console.log(`${isIOS ? 'Dispositivo iOS detectado' : (isReconnection ? 'Reconexão detectada' : 'Novo dispositivo')} na sala, criando oferta`);
				// Pequeno atraso para garantir que o peerConnection esteja pronto
				setTimeout(async () => {
					await createAndSendOffer(isIOS); // true para priorizar compatibilidade iOS
					offerCreatedForRoom[roomId] = true;
				}, 500);
			} else {
				console.log('Já existe oferta ativa para esta sala, ignorando');
			}
			break;
            
        case 'answer':
            // Recebendo resposta do dispositivo
            try {
                await peerConnection.setRemoteDescription(new RTCSessionDescription({
                    type: 'answer',
                    sdp: message.sdp
                }));
                
                console.log('Resposta SDP definida com sucesso');
                connectionInfo.textContent = 'Status da conexão: Resposta recebida';
                
                // Se a resposta veio de um dispositivo iOS, registrar isso
                if (message.senderDeviceType === 'ios') {
                    console.log('Resposta recebida de dispositivo iOS');
                    // Ativar automaticamente a opção de otimização para iOS
                    iosOptimize.checked = true;
                }
            } catch (e) {
                console.error('Erro ao definir a resposta SDP:', e);
                connectionInfo.textContent = 'Status da conexão: Erro ao processar resposta';
            }
            break;
            
        case 'ice-candidate':
            // Recebendo candidato ICE
            if (peerConnection) {
                try {
                    await peerConnection.addIceCandidate(new RTCIceCandidate({
                        candidate: message.candidate,
                        sdpMid: message.sdpMid,
                        sdpMLineIndex: message.sdpMLineIndex
                    }));
                } catch (e) {
                    console.error('Erro ao adicionar candidato ICE:', e);
                }
            }
            break;
            
        case 'error':
            console.error('Erro recebido do servidor:', message.message);
            updateStatus(`Erro: ${message.message}`, 'offline');
            connectionInfo.textContent = `Status da conexão: Erro - ${message.message}`;
            break;
            
        case 'ping':
            // Responder imediatamente com pong para manter a conexão viva
            sendMessage({
                type: 'pong',
                timestamp: Date.now(),
                roomId: roomIdInput.value
            });
            break;
            
        case 'pong':
            // Receber pong do servidor (manter conexão viva)
            lastPongReceived = Date.now();
            // Resetar contador de reconexões quando um pong é recebido
            reconnectAttempts = 0;
            console.log("Pong recebido, conexão confirmada");
            break;
            
        case 'room-info':
            console.log('Informações da sala:', message);
            
            // Verificar se há dispositivos iOS na sala
            if (message.deviceTypes && message.deviceTypes.includes('ios')) {
                console.log('Dispositivo iOS presente na sala, ativando otimizações');
                iosOptimize.checked = true;
            }
            
            updateStatus(`Conectado (${message.clients} ${message.clients === 1 ? 'usuário' : 'usuários'})`, 'online');
            connectionInfo.textContent = `Status da conexão: Na sala com ${message.clients} ${message.clients === 1 ? 'usuário' : 'usuários'}`;
            break;
            
        case 'ios-capabilities-update':
            // Receber informações sobre as capacidades do dispositivo iOS
            console.log('Atualizando para compatibilidade com dispositivo iOS:', message.capabilities);
            
            // Se recebemos informações específicas de um dispositivo iOS, ajustar configurações
            if (message.capabilities) {
                const caps = message.capabilities;
                
                // Ajustar perfil H264 se especificado
                if (caps.h264Profile) {
                    console.log(`Ajustando para perfil H264 específico do iOS: ${caps.h264Profile}`);
                    if (Array.from(h264Profile.options).some(opt => opt.value === caps.h264Profile)) {
                        h264Profile.value = caps.h264Profile;
                    }
                }
                
                // Ajustar formato de pixels se especificado
                if (caps.pixelFormat) {
                    console.log(`Ajustando para formato de pixel específico do iOS: ${caps.pixelFormat}`);
                    if (Array.from(pixelFormat.options).some(opt => opt.value === caps.pixelFormat)) {
                        pixelFormat.value = caps.pixelFormat;
                    }
                }
            }
            break;
            
        case 'peer-disconnected':
            console.log('Peer desconectado:', message.userId);
            connectionInfo.textContent = 'Status da conexão: Peer desconectado';
            break;
    }
}

// Criar e enviar oferta WebRTC
async function createAndSendOffer(optimizeForIOS = false) {
    try {
        // Configurar para alta qualidade de vídeo
        const offerOptions = {
            offerToReceiveAudio: false,
            offerToReceiveVideo: false
        };

        const offer = await peerConnection.createOffer(offerOptions);

        // Definir preferências para SDP baseado nas configurações
        let sdp = offer.sdp;
        
        // Obter bitrate apropriado baseado na qualidade selecionada
		let bitrate = 20000; // 20Mbps para 4K
		switch(videoQuality.value) {
			case '2160p': bitrate = 20000; break; // 20Mbps para 4K 
			case '1440p': bitrate = 12000; break; // 12Mbps para 1440p
			case '1080p': bitrate = 8000; break;  // 8Mbps para 1080p
			case '720p': bitrate = 5000; break;   // 5Mbps para 720p
		}
        
        // Aplicar modificações SDP com base nas configurações
        sdp = setMediaBitrate(sdp, 'video', bitrate);
        
        // Se otimização para iOS está ativada, aplicar otimizações específicas
        if (optimizeForIOS || iosOptimize.checked) {
            console.log('Aplicando otimizações para compatibilidade com iOS');
            
            // 1. Adicionar linha para formato de pixel preferido, se não existir
            const selectedFormat = pixelFormat.value;
            if (selectedFormat && !sdp.includes(selectedFormat)) {
                sdp = addPixelFormatPreference(sdp, selectedFormat);
            }
            
            // 2. Aplicar perfil H264 preferido, se H264 estiver selecionado
            if (videoCodec.value === 'h264') {
                const selectedProfile = h264Profile.value;
                sdp = setH264Profile(sdp, selectedProfile);
            }
            
            // 3. Priorizar codec H264 para compatibilidade com iOS
            sdp = prioritizeCodec(sdp, 'video', 'H264');
        }

        // Aplicar a SDP modificada
        const modifiedOffer = new RTCSessionDescription({
            type: 'offer',
            sdp: sdp
        });

        await peerConnection.setLocalDescription(modifiedOffer);
        console.log("Descrição local definida com sucesso");

        // Adicionar informações sobre configurações da oferta para debug
        const offerInfo = {
            codec: videoCodec.value,
            profile: h264Profile.value,
            pixelFormat: pixelFormat.value,
            optimizedForIOS: optimizeForIOS || iosOptimize.checked,
            resolution: videoQuality.value
        };

        sendMessage({
            type: 'offer',
            sdp: peerConnection.localDescription.sdp,
            roomId: roomIdInput.value,
            offerInfo: offerInfo
        });
        
        connectionInfo.textContent = 'Status da conexão: Oferta enviada';
    } catch (error) {
        console.error('Erro ao criar oferta:', error);
        updateStatus(`Erro ao criar oferta WebRTC: ${error.message}`, 'offline');
        connectionInfo.textContent = 'Status da conexão: Erro ao criar oferta';
    }
}

// Helper para configurar bitrate específico na SDP
function setMediaBitrate(sdp, media, bitrate) {
    // Em rede local, podemos usar bitrates mais altos
    switch(videoQuality.value) {
        case '2160p': // 4K
            bitrate = 20000; // 20Mbps para 4K em rede local
            break;
        case '1440p': // QHD
            bitrate = 12000; // 12Mbps para 1440p
            break;
        case '1080p': // Full HD
            bitrate = 8000;  // 8Mbps para 1080p
            break;
        case '720p':  // HD
            bitrate = 4000;  // 4Mbps para 720p
            break;
    }
    
    const lines = sdp.split('\n');
    let line = -1;

    // Encontrar a seção m=video
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('m=' + media)) {
            line = i;
            break;
        }
    }

    if (line === -1) {
        return sdp;
    }

    // Verificar se já existe uma linha b=AS
    let found = false;
    for (let i = line; i < lines.length; i++) {
        if (lines[i].startsWith('m=') && i !== line) break; // Próxima seção m=

        if (lines[i].startsWith('b=AS:')) {
            // Substituir se o valor atual for muito menor
            const currentBitrate = parseInt(lines[i].substring(5), 10);
            if (currentBitrate < bitrate) {
                lines[i] = 'b=AS:' + bitrate;
            }
            found = true;
            break;
        }
    }

    if (!found) {
        // Adicionar linha b= após a linha 'c=' que segue a seção m=
        let insertPosition = line + 1;
        while (insertPosition < lines.length && !lines[insertPosition].startsWith('c=')) {
            insertPosition++;
        }

        if (insertPosition < lines.length) {
            // Inserir após a linha c=
            insertPosition++;
            const newLines = lines.slice(0, insertPosition);
            newLines.push('b=AS:' + bitrate);
            newLines.push(...lines.slice(insertPosition));
            return newLines.join('\n');
        } else {
            // Caso não encontre a linha c=
            const newLines = lines.slice(0, line + 1);
            newLines.push('b=AS:' + bitrate);
            newLines.push(...lines.slice(line + 1));
            return newLines.join('\n');
        }
    }

    return lines.join('\n');
}

// Helper para adicionar preferência de formato de pixel
function addPixelFormatPreference(sdp, format) {
    // Manipulação específica de SDP para adicionar preferência de formato de pixel
    // Este é um placeholder simplificado - no ambiente real, seria necessário manipular
    // as linhas fmtp específicas para o codec H264
    return sdp;
}

// Helper para configurar perfil H264 específico
function setH264Profile(sdp, profile) {
    if (!profile) return sdp;
    
    const lines = sdp.split('\n');
    let mediaLine = -1;
    let h264PayloadType = null;
    
    // Primeiro encontrar a linha de mídia de vídeo
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('m=video')) {
            mediaLine = i;
            break;
        }
    }
    
    if (mediaLine === -1) return sdp;
    
    // Encontrar payload type para H264
    for (let i = mediaLine; i < lines.length; i++) {
        if (lines[i].startsWith('m=') && i !== mediaLine) break;
        
        if (lines[i].indexOf('a=rtpmap:') !== -1 && lines[i].indexOf('H264') !== -1) {
            h264PayloadType = lines[i].split(':')[1].split(' ')[0];
            break;
        }
    }
    
    if (!h264PayloadType) return sdp;
    
    // Procurar e modificar ou adicionar perfil H264
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].indexOf(`a=fmtp:${h264PayloadType}`) !== -1) {
            if (lines[i].indexOf('profile-level-id=') !== -1) {
                // Substituir perfil existente
                lines[i] = lines[i].replace(/profile-level-id=[^;]+/, `profile-level-id=${profile}`);
            } else {
                // Adicionar perfil se não existir
                lines[i] = `${lines[i]};profile-level-id=${profile}`;
            }
            break;
        }
    }
    
    return lines.join('\n');
}

// Helper para priorizar codec específico
function prioritizeCodec(sdp, mediaType, codecName) {
    const lines = sdp.split('\n');
    let mediaLine = -1;
    let codecPts = [];
    let h264ProfilePt = null; // Preferencial para iOS (profile-level-id 42e01f)
    
    // Encontrar a linha de mídia
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].startsWith(`m=${mediaType}`)) {
            mediaLine = i;
            break;
        }
    }
    
    if (mediaLine === -1) return sdp;
    
    // Primeiro encontrar payload type com profile ideal para iOS
    if (codecName === 'H264' && iosOptimize.checked) {
        for (let i = mediaLine + 1; i < lines.length; i++) {
            if (lines[i].startsWith('m=')) break;
            
            // Encontrar linhas de formato para H264
            if (lines[i].startsWith('a=rtpmap:') && lines[i].includes('H264')) {
                const pt = lines[i].split(':')[1].split(' ')[0];
                
                // Procurar o profile-level-id correspondente
                for (let j = i + 1; j < lines.length; j++) {
                    if (lines[j].startsWith('a=fmtp:' + pt) && 
                        lines[j].includes('profile-level-id=42e01f')) {
                        h264ProfilePt = pt;
                        break;
                    }
                }
                
                // Se encontramos o payload type ideal, podemos parar
                if (h264ProfilePt) break;
                
                // Caso contrário, adicionar à lista de PTs de H264
                codecPts.push(pt);
            }
        }
    }
    
    // Se não encontramos o PT ideal, buscar todos os PTs do codec
    if (!h264ProfilePt) {
        for (let i = mediaLine + 1; i < lines.length; i++) {
            if (lines[i].startsWith('m=')) break;
            
            if (lines[i].startsWith('a=rtpmap:') && lines[i].includes(codecName)) {
                const pt = lines[i].split(':')[1].split(' ')[0];
                codecPts.push(pt);
            }
        }
    }
    
    if ((h264ProfilePt || codecPts.length > 0) && mediaLine !== -1) {
        // Reordenar payload types na linha de mídia para priorizar o codec
        const mLine = lines[mediaLine].split(' ');
        const payloadTypes = mLine.slice(3);
        
        // Remover os payload types do codec desejado
        const filteredPts = payloadTypes.filter(pt => 
            pt !== h264ProfilePt && !codecPts.includes(pt));
        
        // Reordenar com o codec desejado primeiro (PT ideal primeiro, se disponível)
        const priorityPts = h264ProfilePt ? [h264ProfilePt, ...codecPts] : codecPts;
        const newPts = [...priorityPts, ...filteredPts];
        
        // Reconstruir a linha de mídia
        mLine.splice(3, payloadTypes.length, ...newPts);
        lines[mediaLine] = mLine.join(' ');
        
        console.log(`Codec ${codecName} priorizado. Profile iOS: ${h264ProfilePt ? 'encontrado' : 'não encontrado'}`);
    }
    
    return lines.join('\n');
}

// Atualizar status na interface
function updateStatus(message, state) {
    statusDiv.textContent = message;
    statusDiv.className = 'status-badge';
    
    switch (state) {
        case 'online':
            statusDiv.classList.add('status-online');
            break;
        case 'offline':
            statusDiv.classList.add('status-offline');
            break;
        case 'connecting':
            statusDiv.classList.add('status-connecting');
            statusDiv.classList.add('pulse');
            break;
        default:
            statusDiv.classList.add('status-offline');
    }
}

// Iniciar transmissão
async function startStreaming() {
    try {
        if (!roomIdInput.value.trim()) {
            alert("Por favor, informe um ID de sala");
            roomIdInput.classList.add('shake');
            setTimeout(() => roomIdInput.classList.remove('shake'), 500);
            return;
        }

        startButton.disabled = true;
        stopButton.disabled = false;

        // Desabilitar troca de qualidade durante streaming
        roomIdInput.disabled = true;
        videoSource.disabled = true;
        videoQuality.disabled = true;
        frameRate.disabled = true;
        videoCodec.disabled = true;
        h264Profile.disabled = true;
        pixelFormat.disabled = true;
        iosOptimize.disabled = true;

        updateStatus('Iniciando câmera...', 'connecting');
        connectionInfo.textContent = 'Status da conexão: Iniciando câmera';
        
        // Obter stream de vídeo com qualidade selecionada
        await getLocalMediaStream();
        
        updateStatus('Conectando ao servidor...', 'connecting');
        connectionInfo.textContent = 'Status da conexão: Conectando ao servidor';

        // Limpar flag de ofertas
        offerCreatedForRoom = {};

        // Configurar WebRTC
        setupPeerConnection();

        // Conectar ao servidor
        connectWebSocket();
    } catch (error) {
        console.error('Erro ao iniciar transmissão:', error);
        startButton.disabled = false;
        stopButton.disabled = true;
        roomIdInput.disabled = false;
        videoSource.disabled = false;
        videoQuality.disabled = false;
        frameRate.disabled = false;
        videoCodec.disabled = false;
        h264Profile.disabled = false;
        pixelFormat.disabled = false;
        iosOptimize.disabled = false;
        updateStatus(`Erro: ${error.message}`, 'offline');
        connectionInfo.textContent = `Status da conexão: Erro - ${error.message}`;
    }
}

// Parar transmissão
function stopStreaming(notifyServer = true) {
    startButton.disabled = false;
    stopButton.disabled = true;
    roomIdInput.disabled = false;
    videoSource.disabled = false;
    videoQuality.disabled = false;
    frameRate.disabled = false;
    videoCodec.disabled = false;
    h264Profile.disabled = false;
    pixelFormat.disabled = false;
    iosOptimize.disabled = false;

    // Limpar timeout de reconexão, se houver
    if (reconnectTimeout) {
        clearTimeout(reconnectTimeout);
        reconnectTimeout = null;
    }

    // Limpar flag de ofertas
    offerCreatedForRoom = {};

    // Enviar mensagem de despedida, apenas se solicitado
    if (notifyServer && ws && ws.readyState === WebSocket.OPEN) {
        sendMessage({
            type: 'bye',
            roomId: roomIdInput.value
        });
        
        console.log("Enviando mensagem 'bye' ao servidor");
        connectionInfo.textContent = 'Status da conexão: Enviando mensagem de encerramento';
        
        // Dar mais tempo para a mensagem ser enviada antes de fechar
        setTimeout(() => {
            console.log("Fechando conexões após envio de 'bye'");
            closeConnections();
        }, 1000); // Aumentado para 1 segundo
    } else {
        closeConnections();
    }
}

// Função separada para limpar recursos
function closeConnections() {
    // Parar monitoramento de estatísticas
    if (statsInterval) {
        clearInterval(statsInterval);
        statsInterval = null;
    }

    // Parar keep-alive
    stopKeepAliveTimer();

    // Fechar conexão WebRTC
    if (peerConnection) {
        peerConnection.close();
        peerConnection = null;
    }

    // Fechar WebSocket
    if (ws) {
        if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
            ws.close();
        }
        ws = null;
    }

    // Parar streams
    if (localStream) {
        localStream.getTracks().forEach(track => track.stop());
        localStream = null;
        localVideo.srcObject = null;
    }

    // Esconder painel de estatísticas
    statsPanel.classList.add('hidden');
    
    // Resetar contador de reconexão
    reconnectAttempts = 0;
    
    // Resetar timestamp do último pong
    lastPongReceived = 0;

    updateStatus('Desconectado', 'offline');
    connectionInfo.textContent = 'Status da conexão: Desconectado';
}

// Adicionar event listeners
startButton.addEventListener('click', startStreaming);
stopButton.addEventListener('click', () => stopStreaming(true));

// Verificar permissões de câmera quando mudar qualidade
videoQuality.addEventListener('change', async () => {
    if (!localStream && startButton.disabled === false) {
        try {
            // Mostrar preview quando o usuário mudar qualidade
            await getLocalMediaStream();
        } catch (error) {
            console.error("Erro ao atualizar stream:", error);
        }
    }
});

// Evento para mostrar preview quando mudar fonte de vídeo
videoSource.addEventListener('change', async () => {
    if (!localStream && startButton.disabled === false) {
        try {
            await getLocalMediaStream();
        } catch (error) {
            console.error("Erro ao trocar fonte de vídeo:", error);
        }
    }
});

// Adicionar tratamento para evitar timeout
window.addEventListener('focus', () => {
    // Quando a aba recebe foco, verificar se é necessário reconectar
    if (startButton.disabled && !stopButton.disabled && 
        (!ws || ws.readyState !== WebSocket.OPEN)) {
        console.log("Detectada aba inativa. Reconectando...");
        clearTimeout(reconnectTimeout);
        reconnectAttempts = 0;
        connectWebSocket();
    }
});

// Inicializar quando a página carregar
window.addEventListener('DOMContentLoaded', initialize);

// Detectar quando a página é fechada para limpar recursos
window.addEventListener('beforeunload', () => stopStreaming(true));