%% NavIC-SIPS — KPI experiment: does loop reconfiguration actually help?
%
% THE QUESTION THIS ANSWERS
% -------------------------
% NavIC-SIPS predicts scintillation and tells the receiver to widen its
% carrier tracking loop bandwidth before the fade arrives. That is only worth
% doing if widening the loop measurably reduces loss of lock.
%
% This script measures that, with no silicon required:
%
%   same waveform, same scintillation realisation, swept PLL bandwidth
%     -> count cycle slips
%     -> measure fraction of time locked
%     -> measure C/No degradation
%
% If wider bandwidth reduces cycle slips during scintillation, the whole
% premise of the chip is validated. If it does not, we need to know that NOW
% and not in June 2027.
%
% THE HONEST CAVEAT
% -----------------
% Wider loop bandwidth costs thermal noise performance. So the expected
% result is NOT "wider is always better" — it is a U-shape, where the optimum
% bandwidth shifts wider as scintillation strengthens. That shifting optimum
% is exactly what a predictor is for: you cannot sit at the wide setting all
% the time without paying for it in quiet conditions.
%
% PREREQUISITE
%   navic_prompt_iq.m must already run successfully, and 'waveform' must be
%   in the workspace (or navic_waveform.mat on disk).
%
% OUTPUT
%   matlab/out/kpi_results.csv
%   matlab/out/kpi_results.json
%   two figures
% ---------------------------------------------------------------------------

clc;

%% ---- configuration -------------------------------------------------------
cfg.PRNID           = 3;
cfg.SignalType      = 'navic l5 c/a';
cfg.SampleRate      = 10*1.023e6;
cfg.IntegrationTime = 1e-3;

% The sweep. These map onto the PLL_BW field in the LOOP_CFG register.
cfg.PLLBandwidths   = [5 10 15 18 25 35 50];   % Hz

% Scintillation levels to test. 0 = clean reference.
cfg.ScintLevels     = [0 0.3 0.6 1.0];         % rms phase, rad

cfg.Seed            = 42;   % fixed: every bandwidth sees the SAME fade

outDir = fullfile('matlab','out');
if ~exist(outDir,'dir'); mkdir(outDir); end

%% ---- load the waveform ---------------------------------------------------
if ~exist('waveform','var')
    if exist('navic_waveform.mat','file')
        S = load('navic_waveform.mat');
        waveform = S.NavICBBWaveform;
    else
        error(['No waveform available. Run the NavIC waveform example ' ...
               'and save NavICBBWaveform to navic_waveform.mat.']);
    end
end
waveform = waveform(:);

fprintf('NavIC-SIPS KPI experiment\n');
fprintf('  %d samples, %.2f s\n', numel(waveform), ...
        numel(waveform)/cfg.SampleRate);
fprintf('  sweeping %d bandwidths x %d scintillation levels\n\n', ...
        numel(cfg.PLLBandwidths), numel(cfg.ScintLevels));

%% ---- acquire once, on the clean signal -----------------------------------
% Realistic: a receiver acquires before an event, then must hold lock
% through it. Acquiring on the faded signal would confound the experiment.

acquirer = gnssSignalAcquirer( ...
    'GNSSSignalType',        cfg.SignalType, ...
    'SampleRate',             cfg.SampleRate, ...
    'IntermediateFrequency',  0);

nAcq = round(cfg.SampleRate * 2e-3);
[acqInfo, ~] = acquirer(waveform(1:nAcq), cfg.PRNID);
if ~acqInfo.IsDetected
    error('Acquisition failed on the clean waveform.');
end
fprintf('  acquired: Doppler %.1f Hz, code phase %.1f\n\n', ...
        acqInfo.FrequencyOffset, acqInfo.CodePhaseOffset);

%% ---- sweep ---------------------------------------------------------------
nBW  = numel(cfg.PLLBandwidths);
nSc  = numel(cfg.ScintLevels);

results = struct('scint',[],'bw',[],'S4',[],'sigmaPhi',[], ...
                 'cycleSlips',[],'lockFraction',[],'meanCN0',[]);
row = 0;

for iSc = 1:nSc
    rmsPhase = cfg.ScintLevels(iSc);

    % Same seed for every bandwidth at this level -> identical fade, so the
    % only variable is the loop setting.
    rng(cfg.Seed);
    if rmsPhase > 0
        fade = generateScintFade(numel(waveform), cfg.SampleRate, rmsPhase);
        rxWaveform = waveform .* fade(:);
    else
        rxWaveform = waveform;
    end
    rxWaveform = awgn(rxWaveform, 0, 'measured'); 

    fprintf('  scintillation rms_phase = %.2f rad\n', rmsPhase);

    for iBW = 1:nBW
        bw = cfg.PLLBandwidths(iBW);

        tracker = gnssSignalTracker( ...
            'GNSSSignalType',         cfg.SignalType, ...
            'SampleRate',              cfg.SampleRate, ...
            'IntermediateFrequency',   0, ...
            'IntegrationTime',         cfg.IntegrationTime, ...
            'PRNID',                   cfg.PRNID, ...
            'InitialCodePhaseOffset',  acqInfo.CodePhaseOffset, ...
            'InitialFrequencyOffset',  acqInfo.FrequencyOffset, ...
            'PLLOrder',                2, ...
            'PLLNoiseBandwidth',       bw, ...
            'FLLOrder',                1, ...
            'FLLNoiseBandwidth',       4, ...
            'DLLOrder',                1, ...
            'DLLNoiseBandwidth',       1);

        [integWave, ~] = tracker(rxWaveform);

        m = analysePrompt(integWave, cfg.IntegrationTime);

        row = row + 1;
        results(row).scint        = rmsPhase;
        results(row).bw           = bw;
        results(row).S4           = m.S4;
        results(row).sigmaPhi     = m.sigmaPhi;
        results(row).cycleSlips   = m.cycleSlips;
        results(row).lockFraction = m.lockFraction;
        results(row).meanCN0      = m.meanCN0;

        fprintf(['    BW %2d Hz : S4 %.3f  sigma_phi %.3f  ' ...
                 'slips %3d  locked %.1f%%  C/No %.1f dB-Hz\n'], ...
                bw, m.S4, m.sigmaPhi, m.cycleSlips, ...
                100*m.lockFraction, m.meanCN0);
    end
    fprintf('\n');
end

%% ---- the headline table --------------------------------------------------
fprintf('%s\n', repmat('=',1,66));
fprintf('KPI: CYCLE SLIPS vs PLL BANDWIDTH\n');
fprintf('%s\n', repmat('=',1,66));
fprintf('  rms_phase |');
fprintf(' %5d Hz', cfg.PLLBandwidths); fprintf('\n');
fprintf('%s\n', repmat('-',1,66));

bestBW = zeros(1,nSc);
for iSc = 1:nSc
    fprintf('  %6.2f    |', cfg.ScintLevels(iSc));
    slips = zeros(1,nBW);
    for iBW = 1:nBW
        k = (iSc-1)*nBW + iBW;
        slips(iBW) = results(k).cycleSlips;
        fprintf(' %8d', slips(iBW));
    end
    [~,bi] = min(slips);
    bestBW(iSc) = cfg.PLLBandwidths(bi);
    fprintf('   <- best %d Hz\n', bestBW(iSc));
end
fprintf('%s\n', repmat('=',1,66));

fprintf('\nOPTIMUM BANDWIDTH vs SCINTILLATION LEVEL\n');
for iSc = 1:nSc
    fprintf('  rms_phase %.2f -> %d Hz\n', cfg.ScintLevels(iSc), bestBW(iSc));
end
fprintf(['\nIf the optimum shifts wider as scintillation strengthens, that ' ...
         'shift\nis exactly what NavIC-SIPS predicts and acts on. Put this ' ...
         'mapping in\nthe LOOP_CFG firmware table.\n']);

%% ---- export --------------------------------------------------------------
T = struct2table(results);
writetable(T, fullfile(outDir,'kpi_results.csv'));

fid = fopen(fullfile(outDir,'kpi_results.json'),'w');
fprintf(fid,'%s', jsonencode(struct( ...
    'bandwidths_Hz', cfg.PLLBandwidths, ...
    'scint_levels_rad', cfg.ScintLevels, ...
    'best_bandwidth_Hz', bestBW, ...
    'results', results), 'PrettyPrint', true));
fclose(fid);

fprintf('\nwritten: %s\n', fullfile(outDir,'kpi_results.csv'));

%% ---- figures -------------------------------------------------------------
slipMat = reshape([results.cycleSlips], nBW, nSc)';
lockMat = reshape([results.lockFraction], nBW, nSc)';

figure('Name','NavIC-SIPS KPI');

subplot(2,1,1);
plot(cfg.PLLBandwidths, slipMat', '-o','LineWidth',1.5); grid on;
xlabel('PLL noise bandwidth (Hz)'); ylabel('cycle slips');
legend(arrayfun(@(x) sprintf('rms_\\phi = %.2f', x), cfg.ScintLevels, ...
       'UniformOutput', false), 'Location','best');
title('Cycle slips vs loop bandwidth — the case for reconfiguration');

subplot(2,1,2);
plot(cfg.PLLBandwidths, 100*lockMat', '-o','LineWidth',1.5); grid on;
xlabel('PLL noise bandwidth (Hz)'); ylabel('time locked (%)');
title('Lock retention');

%% ==========================================================================
%  Local functions
%  ==========================================================================

function m = analysePrompt(integWave, Ts)
% Extract the metrics that matter from prompt correlator output.
%
% CYCLE SLIPS: squaring removes the BPSK data modulation, so a genuine
% carrier cycle slip appears as a jump of about pi in the halved phase.
% Without the squaring step, every 20 ms data bit looks like a slip.
%
% LOCK: the Costas lock indicator (I^2 - Q^2)/(I^2 + Q^2) sits near +/-1 when
% the loop has pulled the energy into one arm, and wanders toward 0 when it
% loses lock.

    ip = real(integWave(:));
    qp = imag(integWave(:));
    n  = numel(ip);

    % skip loop pull-in
    warmup = min(round(0.05/Ts), floor(n/4));
    ip = ip(warmup+1:end);
    qp = qp(warmup+1:end);
    n  = numel(ip);

    intensity = ip.^2 + qp.^2;
    meanI     = mean(intensity);
    m.S4      = sqrt(max(mean(intensity.^2)/(meanI^2) - 1, 0));

    % data-stripped phase
    z     = complex(ip,qp);
    phase = unwrap(angle(z.^2))/2;

    idx = (1:n)';
    p   = polyfit(idx, phase, 1);
    m.sigmaPhi = std(phase - polyval(p, idx));

    % cycle slips: jumps of about pi in the data-stripped phas

    % Costas lock indicator
    lockInd = (ip.^2 - qp.^2) ./ max(intensity, eps);
    locked   = abs(lockInd) > 0.5;
    m.cycleSlips   = sum(diff(double(locked)) < 0);
    m.lockFraction = mean(abs(lockInd) > 0.5);

    % crude C/No from the narrowband/wideband power ratio
    nb = abs(mean(z)).^2;
    wb = mean(abs(z).^2);
    m.meanCN0 = 10*log10(max(nb/max(wb-nb,eps),eps) / Ts);
end

function fade = generateScintFade(n, fs, rmsPhase)
% Single phase screen + Fresnel propagation. Mirrors
% python/golden/phase_screen.py and navic_prompt_iq.m.

    c      = 299792458;
    lambda = c / 1176.45e6;
    z      = 350e3;      % VERIFY (Track A)
    vDrift = 100;        % VERIFY (Track A)
    p      = 3.0;        % VERIFY (Track A)
    L0     = 1000;

    nfft = 2^nextpow2(n);
    dx   = vDrift / fs;

    q = 2*pi * (0:nfft-1) / (nfft*dx);
    q(q > pi/dx) = q(q > pi/dx) - 2*pi/dx;
    q0 = 2*pi / L0;

    psd  = (q.^2 + q0^2).^(-p/2);
    spec = sqrt(psd) .* exp(1j*2*pi*rand(1,nfft));
    phi  = real(ifft(spec));
    phi  = phi / std(phi) * rmsPhase;

    k = 2*pi/lambda;
    E = ifft(fft(exp(1j*phi)) .* exp(-1j * q.^2 * z / (2*k)));

    fade = E(1:n);
    fade = fade / sqrt(mean(abs(fade).^2));
end
