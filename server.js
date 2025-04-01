/**
 * Servidor WebRTC otimizado para transmissão em alta qualidade 4K/60fps
 * Com foco específico em compatibilidade com formatos iOS e estabilidade de conexão
 */

const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

// Configurações
const PORT = process.env.PORT || 8080;
const LOGGING_ENABLED = true;
const LOG_FILE = './server.log';
const MAX_CONNECTIONS = 10; // Limitado para transmissor + receptor
const KEEP_ALIVE_INTERVAL = 5000; // 5 segundos (era 10s)
const DEAD_CONNECTION_TIMEOUT = 60000; // 60 segundos (era 30s)

// Parâmetros de qualidade para transmissão 4K/60fps
const QUALITY_PRESETS = {
    '2160p': { // 4K
        bitrate: 20000, // 20Mbps para alta qualidade
        width: 3840,
        height: 2160
    },
    '1440p': { // QHD
        bitrate: 12000, // 12Mbps
        width: 2560,
        height: 1440
    },
    '1080p': { // Full HD
        bitrate: 8000, // 8Mbps
        width: 1920,
        height: 1080
    },
    '720p': { // HD
        bitrate: 5000, // 5Mbps
        width: 1280,
        height: 720
    }
};

// Configurações otimizadas para iOS
const IOS_PREFERRED_FORMATS = {
    // Ordem de preferência de formatos de pixel iOS (do mais para o menos preferido)
    pixelFormats: ['420f', '420v', 'BGRA'],
    // Codecs preferidos para compatibilidade com iOS
    videoCodecs: {
        H264: {
            // Profiles compatíveis com iOS, em ordem de preferência
            profiles: ['42e01f', '42001f', '640c1f'],
            // Nível padrão
            level: '1f',
            // Packetization mode preferencial (1 para iOS)
            packetizationMode: 1
        },
        VP8: {
            // VP8 é suportado, mas não preferencial
            priority: 2
        }
    },
    // Parâmetros de transmissão ideais para iOS
    rtpParameters: {
        degradationPreference: 'maintain-resolution', // Priorizar manter resolução
        maxBitrate: 6000000, // 6Mbps máximo (reduzido de 12Mbps)
        minBitrate: 100000 // 100kbps mínimo
    }
};

// Inicializar aplicativo Express
const app = express();
app.use(cors({
    origin: '*',
    methods: ['GET', 'POST', 'DELETE', 'OPTIONS']
}));
app.use(express.json());
app.use(express.static(__dirname));

// Criar servidor HTTP e servidor WebSocket
const server = http.createServer(app);
// Criar servidor WebSocket com configurações otimizadas
const wss = new WebSocket.Server({ 
    server,
    // Aumentar o tamanho máximo dos payloads para suportar vídeo 4K
    maxPayload: 64 * 1024 * 1024, // 64MB
    // Configurar timeout mais generoso para WebSockets
    clientTracking: true,
    // Manter as conexões vivas por mais tempo
    perMessageDeflate: {
        zlibDeflateOptions: {
            chunkSize: 1024,
            memLevel: 7,
            level: 3
        },
        zlibInflateOptions: {
            chunkSize: 10 * 1024
        },
        threshold: 10 * 1024,
        // Importante: NÃO desabilitar contexto entre mensagens
        serverNoContextTakeover: false, 
        clientNoContextTakeover: false
    }
});

// Armazenar conexões
const rooms = {};
const roomData = {};
const roomStats = {};
const clients = new Map();
const lastPingSent = new Map(); // Mapear clientes para tempo do último ping
const lastPongReceived = new Map(); // Mapear clientes para tempo do último pong
const clientDeviceTypes = new Map(); // Armazenar tipo de dispositivo do cliente (iOS, web, etc)
const deviceIdMapping = new Map(); // Mapear deviceId -> clientId para reconhecimento de dispositivos
const clientReconnectCounts = new Map(); // Contar reconexões por cliente

/**
 * Função para logging com timestamp
 * @param {string} message - Mensagem para registro
 * @param {boolean} consoleOnly - Se true, registra apenas no console
 * @param {boolean} isError - Se true, usa console.error em vez de console.log
 */
const log = (message, consoleOnly = false, isError = false) => {
    if (!LOGGING_ENABLED) return;

    const now = new Date();
    const year = now.getFullYear();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    const hours = String(now.getHours()).padStart(2, '0');
    const minutes = String(now.getMinutes()).padStart(2, '0');
    const seconds = String(now.getSeconds()).padStart(2, '0');
    const milliseconds = String(now.getMilliseconds()).padStart(3, '0');
    
    const timestamp = `[${day}/${month}/${year} - ${hours}:${minutes}:${seconds}.${milliseconds}]`;
    const logMessage = `${timestamp} ${message}`;
    
    if (isError) {
        console.error(logMessage);
    } else {
        console.log(logMessage);
    }
    
    if (!consoleOnly && LOG_FILE) {
        try {
            fs.appendFileSync(LOG_FILE, logMessage + '\n');
        } catch (err) {
            console.error(`Erro ao escrever no log: ${err}`);
        }
    }
};

/**
 * Gera um fingerprint consistente para o mesmo dispositivo
 * @param {WebSocket} ws - Conexão WebSocket
 * @param {Object} request - Objeto de requisição HTTP
 * @param {string} deviceId - ID fornecido pelo dispositivo (opcional)
 * @returns {string} - Fingerprint do dispositivo
 */
function generateDeviceFingerprint(ws, request, deviceId) {
    const userAgent = request.headers['user-agent'] || '';
    const ip = request.socket.remoteAddress || '';
    const forwarded = request.headers['x-forwarded-for'] || '';
    
    // Se temos um deviceId, usá-lo como parte principal do fingerprint
    if (deviceId) {
        return crypto.createHash('md5').update(`${deviceId}-${ip}`).digest('hex');
    }
    
    // Se não, usar combinação de IP e User-Agent
    return crypto.createHash('md5').update(`${userAgent}-${ip}-${forwarded}`).digest('hex');
}

/**
 * Encontra um cliente existente pelo fingerprint ou deviceId
 * @param {string} fingerprint - Fingerprint do dispositivo
 * @param {string} deviceId - ID do dispositivo (opcional)
 * @param {string} roomId - ID da sala (opcional)
 * @returns {WebSocket} - Cliente encontrado ou null
 */
function findExistingClient(fingerprint, deviceId, roomId) {
    // Verificar primeiro pelo deviceId, que é mais confiável
    if (deviceId && deviceIdMapping.has(deviceId)) {
        const clientId = deviceIdMapping.get(deviceId);
        if (clients.has(clientId)) {
            return clients.get(clientId);
        }
    }

    // Se não encontrar por deviceId, procurar pelo fingerprint
    for (const [id, client] of clients.entries()) {
        if (client.deviceFingerprint === fingerprint) {
            // Se roomId for fornecido, verificar se o cliente está na sala
            if (roomId && rooms[roomId] && rooms[roomId].includes(client)) {
                return client;
            } else if (!roomId) {
                return client;
            }
        }
    }
    
    return null;
}

/**
 * Remove clientes antigos do mesmo dispositivo
 * @param {string} fingerprint - Fingerprint do dispositivo
 * @param {string} deviceId - ID do dispositivo (opcional)
 * @param {WebSocket} newClient - Novo cliente que substituirá os antigos
 * @param {string} roomId - ID da sala (opcional)
 * @returns {number} - Número de clientes removidos
 */
function removeOldClients(fingerprint, deviceId, newClient, roomId) {
    let removedCount = 0;
    
    // Limpar mapeamento antigo de deviceId
    if (deviceId) {
        deviceIdMapping.set(deviceId, newClient.id);
    }
    
    // Função para realmente remover o cliente
    const removeClient = (client) => {
        // Remover da sala específica
        if (roomId && rooms[roomId]) {
            const index = rooms[roomId].indexOf(client);
            if (index !== -1) {
                rooms[roomId].splice(index, 1);
            }
        }
        
        // Remover dos mapas de tracking
        clients.delete(client.id);
        lastPingSent.delete(client.id);
        lastPongReceived.delete(client.id);
        clientDeviceTypes.delete(client.id);
        
        // Notificar outros clientes na sala
        if (roomId && rooms[roomId]) {
            rooms[roomId].forEach(otherClient => {
                if (otherClient !== newClient && otherClient.readyState === WebSocket.OPEN) {
                    try {
                        otherClient.send(JSON.stringify({
                            type: 'user-left',
                            userId: client.id,
                            reason: 'reconnected'
                        }));
                    } catch (e) {
                        log(`Erro ao notificar saída do cliente ${client.id}: ${e.message}`, false, true);
                    }
                }
            });
        }
        
        // Terminar a conexão
        try {
            client.terminate();
            removedCount++;
            log(`Cliente antigo removido: ${client.id} (deviceId: ${client.deviceId || 'N/A'})`);
        } catch (e) {
            log(`Erro ao terminar cliente antigo ${client.id}: ${e.message}`, false, true);
        }
    };
    
    // Verificar primeiro pelo deviceId
    if (deviceId) {
        for (const [id, client] of clients.entries()) {
            // Não remover o cliente atual
            if (client === newClient) continue;
            
            // Remover se tiver o mesmo deviceId
            if (client.deviceId === deviceId) {
                removeClient(client);
            }
        }
    }
    
    // Verificar também pelo fingerprint para garantir
    for (const [id, client] of clients.entries()) {
        // Não remover o cliente atual
        if (client === newClient) continue;
        
        // Remover se tiver o mesmo fingerprint
        if (client.deviceFingerprint === fingerprint) {
            removeClient(client);
        }
    }
    
    return removedCount;
}

/**
 * Limpar dados antigos de salas vazias
 */
const cleanupEmptyRooms = () => {
    const startTime = Date.now();
    let cleanedCount = 0;
    
    Object.keys(rooms).forEach(roomId => {
        // Verificar se a sala existe e está vazia
        if (!rooms[roomId] || rooms[roomId].length === 0) {
            log(`Limpando sala vazia: ${roomId}`);
            delete rooms[roomId];
            delete roomData[roomId];
            delete roomStats[roomId];
            cleanedCount++;
        } else {
            // Verificar por clientes inativos na sala
            rooms[roomId] = rooms[roomId].filter(client => {
                const isActive = client.readyState === WebSocket.OPEN;
                if (!isActive) {
                    log(`Removendo cliente inativo ${client.id} da sala ${roomId}`);
                    cleanedCount++;
                }
                return isActive;
            });
        }
    });
    
    if (cleanedCount > 0) {
        log(`Limpeza concluída em ${Date.now() - startTime}ms. ${cleanedCount} itens removidos.`);
    }
};

/**
 * Verifica e remove conexões que não respondem
 */
const checkDeadConnections = () => {
    const now = Date.now();
    
    wss.clients.forEach(ws => {
        if (!ws.id) return;

        const lastActivity = lastPongReceived.get(ws.id) || 0;
        const deviceType = clientDeviceTypes.get(ws.id) || 'unknown';
        
        // Timeout muito mais generoso para dispositivos iOS
        const timeoutToUse = deviceType === 'ios' 
            ? DEAD_CONNECTION_TIMEOUT * 5  // 5x mais tempo para iOS (300 segundos)
            : DEAD_CONNECTION_TIMEOUT;
                
        if ((now - lastActivity) > timeoutToUse) {
            log(`Cliente ${ws.id} (${deviceType}) inativo por ${(now - lastActivity)/1000}s, encerrando conexão`);
            
            try {
                // Enviar mensagem "bye" antes de terminar
                if (ws.readyState === WebSocket.OPEN) {
                    try {
                        ws.send(JSON.stringify({
                            type: 'bye',
                            reason: 'timeout'
                        }));
                    } catch (e) {}
                    
                    // Dar mais tempo para bye ser enviado antes de terminar
                    setTimeout(() => {
                        ws.terminate();
                    }, 2000); // Aumentar para 2 segundos
                } else {
                    ws.terminate();
                }
            } catch (e) {
                log(`Erro ao terminar conexão: ${e.message}`, false, true);
            }
        }
    });
};

// Configurar intervalos para limpeza de dados antigos
const cleanupInterval = setInterval(cleanupEmptyRooms, 30000); // a cada 30 segundos
const connectionCheckInterval = setInterval(checkDeadConnections, 15000); // a cada 15 segundos

/**
 * Gera resumo de estatísticas para uma sala
 * @param {string} roomId - ID da sala
 * @returns {object} - Estatísticas da sala
 */
const getRoomStats = (roomId) => {
    if (!roomStats[roomId]) {
        roomStats[roomId] = {
            created: new Date(),
            connections: 0,
            messagesExchanged: 0,
            peakConnections: 0,
            lastActivity: new Date(),
            bandwidth: 0,
            resolution: "unknown",
            fps: 0,
            codec: "unknown",
            pixelFormat: "unknown",
            h264Profile: "unknown",
            activeClients: 0
        };
    }
    
    // Atualizar contagem de clientes ativos
    if (rooms[roomId]) {
        roomStats[roomId].activeClients = rooms[roomId].filter(
            client => client.readyState === WebSocket.OPEN
        ).length;
    }
    
    return roomStats[roomId];
};

/**
 * Atualiza estatísticas da sala quando uma mensagem é processada
 * @param {string} roomId - ID da sala
 * @param {number} messageSize - Tamanho da mensagem em bytes
 */
const updateRoomActivity = (roomId, messageSize = 0) => {
    if (!roomId || !roomStats[roomId]) return;
    
    const stats = roomStats[roomId];
    stats.messagesExchanged++;
    stats.lastActivity = new Date();
    
    // Estimar a largura de banda utilizada
    if (messageSize > 0) {
        // Média móvel da largura de banda com peso maior para valores recentes
        stats.bandwidth = stats.bandwidth * 0.8 + messageSize * 0.2;
    }
};

/**
 * Detecta o tipo de dispositivo cliente com base no User-Agent ou cabeçalhos
 * @param {WebSocket} ws - Conexão WebSocket
 * @param {object} request - Objeto de requisição HTTP
 * @returns {string} - Tipo de dispositivo ('ios', 'android', 'web')
 */
const detectClientDeviceType = (ws, request) => {
    if (!request || !request.headers) return 'unknown';
    
    const userAgent = request.headers['user-agent'] || '';
    
    if (userAgent.includes('iPhone') || userAgent.includes('iPad') || userAgent.includes('iPod')) {
        return 'ios';
    } else if (userAgent.includes('Android')) {
        return 'android';
    } else {
        return 'web';
    }
};

/**
 * Obtém o bitrate ideal com base na resolução
 * @param {string} resolution - Resolução do vídeo (ex: "1080p")
 * @returns {number} - Bitrate em kbps
 */
const getOptimalBitrate = (resolution) => {
    if (!resolution) return QUALITY_PRESETS['1080p'].bitrate;
    
    for (const [key, preset] of Object.entries(QUALITY_PRESETS)) {
        if (resolution.includes(key)) {
            return preset.bitrate;
        }
    }
    
    return QUALITY_PRESETS['1080p'].bitrate; // Default
};

/**
 * Analisa a qualidade da oferta SDP para logging
 * @param {string} sdp - String SDP
 * @returns {object} - Informações sobre a qualidade
 */
const analyzeSdpQuality = (sdp) => {
    if (!sdp) return { hasVideo: false, hasAudio: false };
    
    const result = {
        hasVideo: sdp.includes('m=video'),
        hasAudio: sdp.includes('m=audio'),
        hasH264: sdp.includes('H264'),
        hasVP8: sdp.includes('VP8'),
        hasVP9: sdp.includes('VP9'),
        resolution: "unknown",
        fps: "unknown",
        bitrateKbps: "unknown",
        pixelFormat: "unknown"
    };
    
    // Tentar extrair resolução
    const resMatch = sdp.match(/a=imageattr:.*send.*\[x=([0-9]+)\-?([0-9]*)?\\,y=([0-9]+)\-?([0-9]*)?]/i);
    if (resMatch && resMatch.length >= 4) {
        const width = resMatch[2] || resMatch[1];
        const height = resMatch[4] || resMatch[3];
        result.resolution = `${width}x${height}`;
    }
    
    // Tentar extrair FPS
    const fpsMatch = sdp.match(/a=framerate:([0-9]+)/i);
    if (fpsMatch && fpsMatch.length >= 2) {
        result.fps = `${fpsMatch[1]}fps`;
    }
    
    // Tentar extrair bitrate
    const bitrateMatch = sdp.match(/b=AS:([0-9]+)/i);
    if (bitrateMatch && bitrateMatch.length >= 2) {
        result.bitrateKbps = `${bitrateMatch[1]}kbps`;
        result.bitrate = parseInt(bitrateMatch[1]);
    }
    
    // Procurar profile de H264 level
    if (result.hasH264) {
        const profileMatch = sdp.match(/profile-level-id=([0-9a-fA-F]+)/i);
        if (profileMatch && profileMatch.length >= 2) {
            result.h264Profile = profileMatch[1];
        }
        
        // Detectar formato de pixel se disponível
        if (sdp.includes('420f')) {
            result.pixelFormat = '420f'; // YUV 4:2:0 full-range (preferido pelo iOS)
        } else if (sdp.includes('420v')) {
            result.pixelFormat = '420v'; // YUV 4:2:0 video-range
        } else if (sdp.includes('BGRA')) {
            result.pixelFormat = 'BGRA'; // 32-bit BGRA
        }
    }
    
    return result;
};

/**
 * Otimiza SDP para iOS, focando em H264 com perfis compatíveis e formatos de pixel
 * @param {string} sdp - SDP original
 * @param {string} clientType - Tipo de cliente ('ios', 'web', etc)
 * @param {string} resolution - Resolução desejada (opcional)
 * @returns {string} - SDP otimizado
 */
const enhanceSdpForIOS = (sdp, clientType = 'web', resolution = null) => {
    if (!sdp.includes('m=video')) return sdp;
    
    const lines = sdp.split('\n');
    const newLines = [];
    let inVideoSection = false;
    let videoSectionModified = false;
    let h264PayloadType = null;
    
    // Determinar o bitrate apropriado com base na resolução
    const bitrate = getOptimalBitrate(resolution);
    
    // Fase 1: Encontrar payload type para H264
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (line.startsWith('a=rtpmap:') && line.includes('H264')) {
            h264PayloadType = line.split(':')[1].split(' ')[0];
            break;
        }
    }
    
    // Fase 2: Modificar o SDP para otimizar para iOS
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        
        // Detectar seção de vídeo
        if (line.startsWith('m=video')) {
            inVideoSection = true;
            
            // Se for cliente iOS, reordenar os codecs para priorizar H264
            if (clientType === 'ios' && h264PayloadType) {
                // Tokenizar a linha m=video
                const parts = line.split(' ');
                const payloadTypes = parts.slice(3);
                
                // Remover h264PayloadType da lista
                const index = payloadTypes.indexOf(h264PayloadType);
                if (index !== -1) {
                    payloadTypes.splice(index, 1);
                    
                    // Reordenar com H264 primeiro
                    const newPayloadTypes = [h264PayloadType, ...payloadTypes];
                    const newLine = `${parts[0]} ${parts[1]} ${parts[2]} ${newPayloadTypes.join(' ')}`;
                    newLines.push(newLine);
                    continue;
                }
            }
            newLines.push(line);
            continue;
        } else if (line.startsWith('m=')) {
            inVideoSection = false;
        }
        
        // Para seção de vídeo, adicionar bitrate se não existir
        if (inVideoSection && line.startsWith('c=') && !videoSectionModified) {
            newLines.push(line);
            
            // Verificar se já existe uma linha b=AS
            let hasAS = false;
            let existingBitrate = 0;
            for (let j = i + 1; j < lines.length && !lines[j].startsWith('m='); j++) {
                if (lines[j].startsWith('b=AS:')) {
                    hasAS = true;
                    existingBitrate = parseInt(lines[j].substring(5));
                    break;
                }
            }
            
            // Adicionar linha de bitrate alto para vídeo apenas se não existir ou se for menor que o desejado
            if (!hasAS) {
                newLines.push(`b=AS:${bitrate}`);
                videoSectionModified = true;
            } else if (existingBitrate < bitrate) {
                // Se o bitrate existente for menor, substituiremos mais tarde
                videoSectionModified = true;
            }
            continue;
        }
        
        // Se encontramos uma linha b=AS: na seção de vídeo e queremos modificá-la
        if (inVideoSection && line.startsWith('b=AS:') && videoSectionModified) {
            const existingBitrate = parseInt(line.substring(5));
            if (existingBitrate < bitrate) {
                newLines.push(`b=AS:${bitrate}`);
            } else {
                newLines.push(line);
            }
            continue;
        }
        
        // Otimizações específicas para H264 usado por iOS
        if (inVideoSection && line.startsWith('a=fmtp:') && h264PayloadType && line.includes(h264PayloadType)) {
            // Para clientes iOS, otimizar o perfil H264
            if (clientType === 'ios') {
                // Verificar se já tem profile-level-id
                if (line.includes('profile-level-id=')) {
                    // Verificar se o perfil já é um dos perfis compatíveis com iOS
                    let hasCompatibleProfile = false;
                    for (const profile of IOS_PREFERRED_FORMATS.videoCodecs.H264.profiles) {
                        if (line.includes(`profile-level-id=${profile}`)) {
                            hasCompatibleProfile = true;
                            break;
                        }
                    }
                    
                    // Se não tem perfil compatível, substituir pelo primeiro perfil compatível
                    if (!hasCompatibleProfile) {
                        // Obter o perfil atual
                        const currentProfile = line.match(/profile-level-id=([0-9a-fA-F]+)/i)[1];
                        // Substituir pelo perfil preferido do iOS
                        const newLine = line.replace(
                            `profile-level-id=${currentProfile}`,
                            `profile-level-id=${IOS_PREFERRED_FORMATS.videoCodecs.H264.profiles[0]}`
                        );
                        newLines.push(newLine);
                        continue;
                    }
                } else {
                    // Se não tem profile-level-id, adicionar o perfil preferido
                    const newLine = `${line};profile-level-id=${IOS_PREFERRED_FORMATS.videoCodecs.H264.profiles[0]}`;
                    newLines.push(newLine);
                    continue;
                }
                
                // Garantir packetization-mode=1 (preferido pelo iOS)
                if (!line.includes('packetization-mode=')) {
                    const newLine = `${line};packetization-mode=${IOS_PREFERRED_FORMATS.videoCodecs.H264.packetizationMode}`;
                    newLines.push(newLine);
                    continue;
                }
            }
        }
        
        newLines.push(line);
    }
    
    return newLines.join('\n');
};

/**
 * Ajusta o SDP para priorizar formatos compatíveis com o dispositivo do cliente
 * @param {string} sdp - String SDP original
 * @param {string} deviceType - Tipo de dispositivo ('ios', 'android', 'web')
 * @param {object} quality - Informações de qualidade da oferta (opcional)
 * @returns {string} - SDP otimizado
 */
const optimizeSdpForDevice = (sdp, deviceType, quality = null) => {
    // Se for iOS, usar otimizações específicas
    if (deviceType === 'ios') {
        return enhanceSdpForIOS(sdp, deviceType, quality?.resolution);
    }
    
    // Para outros dispositivos, apenas ajustar bitrate e qualidade geral
    const resolution = quality?.resolution || null;
    return enhanceSdpForHighQuality(sdp, resolution);
};

/**
 * Melhora SDP para otimizar para alta qualidade sem causar conflitos de payload
 * @param {string} sdp - SDP original
 * @param {string} resolution - Resolução do vídeo (opcional)
 * @returns {string} - SDP otimizado
 */
const enhanceSdpForHighQuality = (sdp, resolution = null) => {
    if (!sdp.includes('m=video')) return sdp;
    
    const lines = sdp.split('\n');
    const newLines = [];
    let inVideoSection = false;
    let videoSectionModified = false;
    let videoLineIndex = -1;
    
    // Determinar o bitrate apropriado com base na resolução
    const bitrate = getOptimalBitrate(resolution);
    
    // Primeiro, vamos encontrar a linha 'm=video' e analisar
    for (let i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('m=video')) {
            videoLineIndex = i;
            break;
        }
    }
    
    // Se não encontramos seção de vídeo, retornamos o SDP sem alterações
    if (videoLineIndex === -1) return sdp;
    
    // Agora processamos linha por linha
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        
        // Detectar seção de vídeo
        if (line.startsWith('m=video')) {
            inVideoSection = true;
            // Não modificamos a linha m=video diretamente para evitar conflitos de payload
            newLines.push(line);
            continue;
        } else if (line.startsWith('m=')) {
            inVideoSection = false;
        }
        
        // Para seção de vídeo, adicionar bitrate se não existir
        if (inVideoSection && line.startsWith('c=') && !videoSectionModified) {
            newLines.push(line);
            
            // Verificar se já existe uma linha b=AS
            let hasAS = false;
            let existingBitrate = 0;
            for (let j = i + 1; j < lines.length && !lines[j].startsWith('m='); j++) {
                if (lines[j].startsWith('b=AS:')) {
                    hasAS = true;
                    existingBitrate = parseInt(lines[j].substring(5));
                    break;
                }
            }
            
            // Adicionar linha de bitrate alto para vídeo apenas se não existir ou se for menor que o desejado
            if (!hasAS) {
                newLines.push(`b=AS:${bitrate}`);
                videoSectionModified = true;
            } else if (existingBitrate < bitrate) {
                // Se o bitrate existente for menor, substituiremos mais tarde
                videoSectionModified = true;
            }
            continue;
        }
        
        // Se encontramos a linha b=AS: na seção de vídeo e queremos modificá-la
        if (inVideoSection && line.startsWith('b=AS:') && videoSectionModified) {
            const existingBitrate = parseInt(line.substring(5));
            if (existingBitrate < bitrate) {
                newLines.push(`b=AS:${bitrate}`);
            } else {
                newLines.push(line);
            }
            continue;
        }
        
        // Não modificamos mais o profile-level-id para evitar conflitos
        newLines.push(line);
    }
    
    return newLines.join('\n');
};

// Manipular conexões WebSocket
wss.on('connection', (ws, request) => {
    // Identificar cliente
    const clientId = uuidv4();
    ws.id = clientId;
    ws.isAlive = true;
    
    // Detectar tipo de dispositivo
    const deviceType = detectClientDeviceType(ws, request);
    clientDeviceTypes.set(clientId, deviceType);
    
    log(`Nova conexão WebSocket estabelecida: ${clientId} (${deviceType})`);
    
    // Inicializar tempos de ping/pong
    lastPingSent.set(clientId, 0);
    lastPongReceived.set(clientId, Date.now()); // Inicializa com tempo atual para evitar timeout imediato
    
    let roomId = null;
    
    // Configurar event handlers para ping/pong
    ws.on('pong', () => {
        ws.isAlive = true;
        lastPongReceived.set(ws.id, Date.now());
        
        // Limpar flag de segunda chance
        ws.secondChance = false;
    });
    
    // Tratamento de erros específico
    ws.on('error', (error) => {
        log(`Erro WebSocket para cliente ${ws.id}: ${error.message}`, false, true);
    });
    
    // Armazenar o cliente no mapa global
    clients.set(clientId, ws);
    
    // Processar mensagens
    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            
            // Obter roomId da mensagem ou usar padrão
            const msgRoomId = data.roomId || 'ios-camera';
            
            if (data.type === 'join') {
                roomId = data.roomId || 'ios-camera';
                
                // Extrair informações do dispositivo para identificação
                const deviceId = data.deviceId;
                const isReconnect = data.reconnect === true;
                
                // Gerar fingerprint do dispositivo
                const deviceFingerprint = generateDeviceFingerprint(ws, request, deviceId);
                ws.deviceFingerprint = deviceFingerprint;
                ws.deviceId = deviceId;
                
                // Verificar se o dispositivo já está na sala para prevenir conexões duplicadas
                if (deviceId) {
                    deviceIdMapping.set(deviceId, clientId);
                }
                
                // Se for uma reconexão ou temos um fingerprint que coincide com cliente existente
                const existingClient = findExistingClient(deviceFingerprint, deviceId, roomId);
                if (existingClient && existingClient !== ws) {
                    log(`Detectada reconexão de dispositivo - removendo cliente antigo: ${existingClient.id}`);
                    
                    // Incrementar contagem de reconexões
                    const reconnectCount = (clientReconnectCounts.get(deviceFingerprint) || 0) + 1;
                    clientReconnectCounts.set(deviceFingerprint, reconnectCount);
                    
                    // Remover cliente antigo
                    removeOldClients(deviceFingerprint, deviceId, ws, roomId);
                } else if (isReconnect) {
                    log(`Cliente ${ws.id} indicou reconexão, mas não encontrado cliente antigo.`);
                }
                
                // Garantir que a sala exista
                if (!rooms[roomId]) {
                    rooms[roomId] = [];
                    roomData[roomId] = { offers: [], answers: [], iceCandidates: [] };
                    log(`Nova sala criada: ${roomId}`);
                }
                
                // Verificar se o cliente já está na sala para evitar duplicação
                const existingClientIndex = rooms[roomId].findIndex(client => client.id === ws.id);
                if (existingClientIndex >= 0) {
                    log(`Cliente ${ws.id} já está na sala ${roomId}, ignorando join duplicado`);
                    return;
                }
                
                // Limitar número de conexões por sala
                if (rooms[roomId].length >= MAX_CONNECTIONS) {
                    ws.send(JSON.stringify({
                        type: 'error',
                        message: `Sala cheia, máximo ${MAX_CONNECTIONS} conexões permitidas`
                    }));
                    log(`Tentativa de conexão rejeitada - sala cheia: ${roomId}`, false, true);
                    return;
                }
                
                // Adicionar à sala
                rooms[roomId].push(ws);
                
                // Atualizar estatísticas
                const stats = getRoomStats(roomId);
                stats.connections++;
                stats.peakConnections = Math.max(stats.peakConnections, rooms[roomId].length);
                
                log(`Cliente ${ws.id} (${deviceType}) entrou na sala: ${roomId}, total na sala: ${rooms[roomId].length}`);
                
                // Notificar outros clientes
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        // Construir objeto de notificação
                        const notification = { 
                            type: 'user-joined',
                            userId: ws.id,
                            deviceType: deviceType
                        };
                        
                        // Se for reconexão, incluir essa informação
                        if (isReconnect) {
                            notification.isReconnect = true;
                        }
                        
                        // Enviar notificação
                        client.send(JSON.stringify(notification));
                    }
                });
                
                // Enviar dados existentes (ofertas e candidatos ICE) - apenas o mais recente
                if (roomData[roomId].offers.length > 0) {
                    const latestOffer = roomData[roomId].offers[roomData[roomId].offers.length - 1];
                    
                    // Otimizar SDP para o dispositivo do cliente
                    if (latestOffer.sdp) {
                        // Criar cópia para não modificar a original
                        const optimizedOffer = { ...latestOffer };
                        optimizedOffer.sdp = optimizeSdpForDevice(latestOffer.sdp, deviceType);
                        ws.send(JSON.stringify(optimizedOffer));
                    } else {
                        ws.send(JSON.stringify(latestOffer));
                    }
                    
                    log(`Enviando oferta existente para novo cliente ${ws.id}`);
                }
                
                // Enviar apenas os últimos 10 candidatos ICE para reduzir tráfego
                if (roomData[roomId].iceCandidates.length > 0) {
                    const recentCandidates = roomData[roomId].iceCandidates.slice(-10);
                    recentCandidates.forEach(candidate => {
                        ws.send(JSON.stringify(candidate));
                    });
                    log(`Enviando ${recentCandidates.length} candidatos ICE para novo cliente ${ws.id}`);
                }
                
                // Enviar estatísticas da sala
                ws.send(JSON.stringify({
                    type: 'room-info',
                    clients: rooms[roomId].length,
                    room: roomId,
                    deviceTypes: Array.from(new Set(
                        rooms[roomId]
                            .map(client => clientDeviceTypes.get(client.id))
                            .filter(type => type)
                    ))
                }));
            } 
            // Processar oferta SDP (otimizar para dispositivo específico)
            else if (data.type === 'offer' && roomId) {
                const deviceType = clientDeviceTypes.get(ws.id) || 'web';
                log(`Oferta SDP recebida de ${ws.id} (${deviceType}) na sala ${roomId} com comprimento ${data.sdp ? data.sdp.length : 0}`);
                
                // Analisar qualidade da oferta para log
                let quality = null;
                if (data.sdp) {
                    quality = analyzeSdpQuality(data.sdp);
                    log(`Qualidade da oferta: video=${quality.hasVideo}, audio=${quality.hasAudio}, codec=${quality.hasH264 ? 'H264' : (quality.hasVP9 ? 'VP9' : (quality.hasVP8 ? 'VP8' : 'unknown'))}, resolução=${quality.resolution}, fps=${quality.fps}, bitrate=${quality.bitrateKbps}, formato=${quality.pixelFormat}`);
                    
                    // Atualizar estatísticas da sala
                    const stats = getRoomStats(roomId);
                    stats.resolution = quality.resolution;
                    stats.fps = quality.fps;
                    stats.codec = quality.hasH264 ? 'H264' : (quality.hasVP9 ? 'VP9' : (quality.hasVP8 ? 'VP8' : 'unknown'));
                    stats.pixelFormat = quality.pixelFormat;
                    stats.h264Profile = quality.h264Profile || 'unknown';
                    
                    // Otimizar SDP para o tipo de dispositivo de destino
                    // Verificar se há dispositivos iOS na sala
                    const hasIOSClients = rooms[roomId].some(client => 
                        client !== ws && clientDeviceTypes.get(client.id) === 'ios'
                    );
                    
                    // Se houverem dispositivos iOS na sala, otimizar especificamente para iOS
                    if (hasIOSClients) {
                        log(`Otimizando SDP para compatibilidade com iOS na sala ${roomId}`);
                        data.sdp = optimizeSdpForDevice(data.sdp, 'ios', quality);
                    } else {
                        // Se não houver dispositivos iOS, otimizar para alta qualidade em geral
                        data.sdp = enhanceSdpForHighQuality(data.sdp, quality.resolution);
                    }
                }
                
                // Armazenar oferta
                data.senderId = ws.id;
                data.timestamp = Date.now();
                data.senderDeviceType = deviceType;
                roomData[roomId].offers.push(data);
                
                // Limitar número de ofertas armazenadas
                if (roomData[roomId].offers.length > 5) {
                    roomData[roomId].offers = roomData[roomId].offers.slice(-5);
                }
                
                // Encaminhar oferta para outros clientes
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        // Obter tipo de dispositivo do cliente de destino
                        const targetDeviceType = clientDeviceTypes.get(client.id) || 'web';
                        
                        // Se o cliente de destino for iOS, otimizar especificamente para iOS
                        let optimizedSdp = data.sdp;
                        if (targetDeviceType === 'ios') {
                            optimizedSdp = optimizeSdpForDevice(data.sdp, 'ios', quality);
                        }
                        
                        // Enviar a oferta otimizada
                        client.send(JSON.stringify({
                            ...data,
                            sdp: optimizedSdp
                        }));
                    }
                });
                
                updateRoomActivity(roomId, message.length);
            } 
            // Processar resposta SDP
            else if (data.type === 'answer' && roomId) {
                const deviceType = clientDeviceTypes.get(ws.id) || 'web';
                log(`Resposta SDP recebida de ${ws.id} (${deviceType}) na sala ${roomId}`);
                
                // Analisar qualidade da resposta
                if (data.sdp) {
                    const quality = analyzeSdpQuality(data.sdp);
                    log(`Qualidade da resposta: video=${quality.hasVideo}, audio=${quality.hasAudio}, codec=${quality.hasH264 ? 'H264' : (quality.hasVP9 ? 'VP9' : (quality.hasVP8 ? 'VP8' : 'unknown'))}, resolução=${quality.resolution}, fps=${quality.fps}, pixelFormat=${quality.pixelFormat}`);
                    
                    // Se for uma resposta de um dispositivo iOS, registrar os formatos para otimização futura
                    if (deviceType === 'ios') {
                        log(`Resposta recebida de dispositivo iOS com formato de pixel: ${quality.pixelFormat}, profile H264: ${quality.h264Profile}`);
                    }
                }
                
                // Armazenar resposta
                data.senderId = ws.id;
                data.timestamp = Date.now();
                data.senderDeviceType = deviceType;
                roomData[roomId].answers.push(data);
                
                // Limitar número de respostas armazenadas
                if (roomData[roomId].answers.length > 5) {
                    roomData[roomId].answers = roomData[roomId].answers.slice(-5);
                }
                
                // Encaminhar resposta para outros clientes
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify(data));
                    }
                });
                
                updateRoomActivity(roomId, message.length);
            } 
            // Processar candidatos ICE
            else if (data.type === 'ice-candidate' && roomId) {
                log(`Candidato ICE recebido de ${ws.id}`);
                
                // Verificar se é um candidato duplicado
                const exists = roomData[roomId].iceCandidates.some(c => 
                    c.candidate === data.candidate && 
                    c.sdpMid === data.sdpMid && 
                    c.sdpMLineIndex === data.sdpMLineIndex
                );
                
                if (!exists) {
                    // Armazenar candidato
                    data.senderId = ws.id;
                    data.timestamp = Date.now();
                    data.senderDeviceType = clientDeviceTypes.get(ws.id) || 'web';
                    roomData[roomId].iceCandidates.push(data);
                    
                    // Limitar número de candidatos armazenados
                    if (roomData[roomId].iceCandidates.length > 30) {
                        roomData[roomId].iceCandidates = roomData[roomId].iceCandidates.slice(-30);
                    }
                    
                    // Encaminhar candidato para outros clientes
                    rooms[roomId].forEach(client => {
                        if (client !== ws && client.readyState === WebSocket.OPEN) {
                            client.send(JSON.stringify(data));
                        }
                    });
                }
                
                updateRoomActivity(roomId, message.length);
            } 
            // Processar bye (desconexão)
            else if (data.type === 'bye' && roomId) {
                log(`Mensagem 'bye' recebida de ${ws.id}`);
                
                // Notificar outros clientes sobre desconexão
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({
                            type: 'peer-disconnected',
                            userId: ws.id,
                            deviceType: clientDeviceTypes.get(ws.id) || 'unknown'
                        }));
                    }
                });
                
                updateRoomActivity(roomId);
            }
            // Processar ping
            else if (data.type === 'ping') {
                // Responder com pong imediatamente 
                ws.send(JSON.stringify({
                    type: 'pong',
                    timestamp: Date.now()
                }));
                
                // Atualizar última atividade
                lastPongReceived.set(ws.id, Date.now());
                ws.isAlive = true;
                ws.secondChance = false;
                
                // Atualizar atividade da sala apenas se houver uma
                if (roomId) {
                    updateRoomActivity(roomId);
                }
            }
            // Processar pong
            else if (data.type === 'pong') {
                // Registrar recebimento de pong
                lastPongReceived.set(ws.id, Date.now());
                ws.isAlive = true;
                ws.secondChance = false;
                
                // Atualizar atividade da sala se houver uma
                if (roomId) {
                    updateRoomActivity(roomId);
                }
            }
            // Processar mensagens de capacidade (recurso específico para iOS)
            else if (data.type === 'ios-capabilities' && roomId) {
                // Receber informações de capacidade do dispositivo iOS
                log(`Informações de capacidade do iOS recebidas de ${ws.id}: ${JSON.stringify(data.capabilities)}`);
                
                // Armazenar as capacidades para uso futuro
                const roomStats = getRoomStats(roomId);
                roomStats.iosCapabilities = data.capabilities;
                
                // Notificar outros clientes sobre as capacidades do iOS
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({
                            type: 'ios-capabilities-update',
                            userId: ws.id,
                            capabilities: data.capabilities
                        }));
                    }
                });
                
                updateRoomActivity(roomId);
            }
            // Processar outras mensagens para a sala
            else if (roomId) {
                log(`Mensagem tipo "${data.type}" recebida de ${ws.id}`);
                
                // Encaminhar mensagem para outros clientes na sala
                rooms[roomId].forEach(client => {
                    if (client !== ws && client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify(data));
                    }
                });
                
                updateRoomActivity(roomId, message.length);
            }
        } catch (e) {
            log(`Erro ao processar mensagem WebSocket: ${e.message}`, false, true);
            log(`Mensagem problemática: ${message.toString().substring(0, 100)}...`, false, true);
            try {
                ws.send(JSON.stringify({
                    type: 'error', 
                    message: 'Invalid message format'
                }));
            } catch (sendError) {
                log(`Erro ao enviar mensagem de erro: ${sendError.message}`, false, true);
            }
        }
    });
    
    // Manipular desconexão
    ws.on('close', () => {
        log(`Conexão com cliente ${ws.id} fechada`);
        
        clients.delete(ws.id);
        clientDeviceTypes.delete(ws.id);
        lastPingSent.delete(ws.id);
        lastPongReceived.delete(ws.id);
        
        // Remover deviceId->clientId mapping apenas se for para este cliente
        if (ws.deviceId) {
            const mappedClientId = deviceIdMapping.get(ws.deviceId);
            if (mappedClientId === ws.id) {
                deviceIdMapping.delete(ws.deviceId);
            }
        }
        
        if (roomId && rooms[roomId]) {
            // Remover cliente da sala
            const index = rooms[roomId].indexOf(ws);
            if (index !== -1) {
                rooms[roomId].splice(index, 1);
            }
            
            log(`Cliente ${ws.id} saiu da sala: ${roomId}, restantes: ${rooms[roomId].length}`);
            
            // Atualizar estatísticas
            const stats = getRoomStats(roomId);
            stats.connections--;
            
            // Remover sala se vazia
            if (rooms[roomId].length === 0) {
                log(`Sala vazia: ${roomId} - será limpa na próxima verificação`);
            } else {
                // Notificar outros clientes sobre a saída
                rooms[roomId].forEach(client => {
                    if (client.readyState === WebSocket.OPEN) {
                        client.send(JSON.stringify({ 
                            type: 'user-left',
                            userId: ws.id,
                            deviceType: clientDeviceTypes.get(ws.id) || 'unknown'
                        }));
                    }
                });
            }
        }
    });
});

// Configurar ping periódico para manter conexões vivas
const pingInterval = setInterval(() => {
    const now = Date.now();
    wss.clients.forEach(ws => {
        if (!ws.id) return; // Ignorar conexões sem ID
        
        // Verificar se o cliente está inativo há muito tempo
        const lastPong = lastPongReceived.get(ws.id) || 0;
        const inactiveTime = now - lastPong;
        
        // Definir intervalo de ping com base no tipo de dispositivo
        const deviceType = clientDeviceTypes.get(ws.id) || 'unknown';
        const pingIntervalForDevice = deviceType === 'ios' ? KEEP_ALIVE_INTERVAL * 1.2 : KEEP_ALIVE_INTERVAL;
        
        // Enviar ping apenas se o último foi há pelo menos o intervalo definido
        const lastPing = lastPingSent.get(ws.id) || 0;
        const timeSinceLastPing = now - lastPing;
        
        if (timeSinceLastPing >= pingIntervalForDevice) {
            // Enviar ping via WebSocket nativo
            try {
                ws.ping();
            } catch (e) {
                log(`Erro ao enviar ping WebSocket para ${ws.id}: ${e.message}`, false, true);
            }
            
            // Enviar também ping como mensagem JSON (mais compatível)
            if (ws.readyState === WebSocket.OPEN) {
                try {
                    ws.send(JSON.stringify({
                        type: 'ping',
                        timestamp: now,
                        keepAlive: true
                    }));
                    
                    // Registrar o tempo do ping
                    lastPingSent.set(ws.id, now);
                    log(`Ping enviado para ${ws.id}`, true); // Log verbose
                } catch (e) {
                    log(`Erro ao enviar ping JSON para ${ws.id}: ${e.message}`, false, true);
                }
            }
        }
    });
}, KEEP_ALIVE_INTERVAL);

// Limpar intervalo quando o servidor é fechado
wss.on('close', () => {
    clearInterval(pingInterval);
    clearInterval(cleanupInterval);
    clearInterval(connectionCheckInterval);
    
    log('Servidor WebRTC encerrado');
});

// Rota padrão para o cliente WebRTC
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// Rota para verificar status do servidor
app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        connections: wss.clients.size,
        rooms: Object.keys(rooms).length,
        timestamp: new Date().toISOString(),
        uptime: process.uptime()
    });
});

// Informações sobre o servidor
app.get('/info', (req, res) => {
    // Preparar estatísticas de salas
    const roomsInfo = {};
    Object.keys(roomStats).forEach(roomId => {
        const stats = roomStats[roomId];
        roomsInfo[roomId] = {
            connections: stats.connections,
            activeClients: stats.activeClients,
            messagesExchanged: stats.messagesExchanged,
            resolution: stats.resolution,
            fps: stats.fps,
            codec: stats.codec,
            pixelFormat: stats.pixelFormat || 'unknown',
            h264Profile: stats.h264Profile || 'unknown',
            created: stats.created,
            lastActivity: stats.lastActivity
        };
    });
    
    // Contagem de clientes por tipo
    const deviceCounts = {
        ios: 0,
        android: 0,
        web: 0,
        unknown: 0
    };
    
    clientDeviceTypes.forEach(type => {
        deviceCounts[type] = (deviceCounts[type] || 0) + 1;
    });
    
    res.json({
        clients: wss.clients.size,
        rooms: Object.keys(rooms).length,
        deviceTypes: deviceCounts,
        roomsInfo: roomsInfo,
        uptime: process.uptime(),
        startTime: new Date(Date.now() - process.uptime() * 1000).toISOString()
    });
});

// Obter informações sobre uma sala específica
app.get('/room/:roomId/info', (req, res) => {
    const roomId = req.params.roomId;
    
    if (!rooms[roomId]) {
        return res.status(404).json({ error: 'Sala não encontrada' });
    }
    
    const stats = getRoomStats(roomId);
    
    // Contar dispositivos de cada tipo na sala
    const deviceCounts = {};
    rooms[roomId].forEach(client => {
        const deviceType = clientDeviceTypes.get(client.id) || 'unknown';
        deviceCounts[deviceType] = (deviceCounts[deviceType] || 0) + 1;
    });
    
    // Calcular clientes ativos (apenas conexões abertas)
    const activeClients = rooms[roomId].filter(client => client.readyState === WebSocket.OPEN).length;
    
    res.json({
        id: roomId,
        clients: rooms[roomId].length,
        activeClients: activeClients,
        deviceTypes: deviceCounts,
        connections: stats.connections,
        messagesExchanged: stats.messagesExchanged,
        resolution: stats.resolution,
        fps: stats.fps,
        codec: stats.codec,
        pixelFormat: stats.pixelFormat || 'unknown',
        h264Profile: stats.h264Profile || 'unknown',
        created: stats.created,
        lastActivity: stats.lastActivity
    });
});

// Função para obter endereços IP locais disponíveis
function getLocalIPs() {
    const interfaces = os.networkInterfaces();
    const addresses = [];
    
    Object.keys(interfaces).forEach(interfaceName => {
        interfaces[interfaceName].forEach(iface => {
            // Ignorar endereços IPv6 e loopback
            if (iface.family === 'IPv4' && !iface.internal) {
                addresses.push(iface.address);
            }
        });
    });
    
    return addresses;
}

// Iniciar servidor
server.listen(PORT, () => {
    const addresses = getLocalIPs();
    
    log(`Servidor WebRTC rodando na porta ${PORT}`);
    log(`Interfaces de rede disponíveis: ${addresses.join(', ')}`);
    log(`Interface web disponível em http://localhost:${PORT}`);
    log(`Use um dos seguintes endereços para conexão externa:`);
    addresses.forEach(addr => {
        log(`  http://${addr}:${PORT}`);
    });
});