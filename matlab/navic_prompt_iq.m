%% NavIC-SIPS — prompt I/Q extraction chain
%
% Produces POST-CORRELATION PROMPT I/Q from a NavIC L5 waveform.
%
% WHY: the submitted proposal has the SoC computing S4 / sigma_phi from RAW
% front-end I/Q. That cannot work — raw front-end output is pre-correlation,
% every satellite mixed together below the noise floor. Per-satellite
% amplitude and carrier phase only exist after despreading and tracking.
% This script shows exactly where they appear: the prompt correlator output.
%
% HOW TO RUN
%   1. Run the NavIC waveform example first:
%          openExample('satcom/NavICWaveformGenerationExample')
%      Set WaveformType = "NavIC L5-SPS", PRNID = 3, numNavDataBits = 40.
%
%      NOTE: that example has three INVERTED conditions. Each tests for
%      "NavIC L5-SPS" where it means "NavIC L1-SPS". Fix all three or the
%      sample count comes out at half the correct value:
%        - the oneBitduration if/else  (L5 is 50 bps -> 20 ms, not 10 ms)
%        - the L1 dataset download block
%        - the L1PRNInit load block
%
%   2. Then:
%          waveform = NavICBBWaveform;
%          navic_prompt_iq
%
% OUTPUT
%   matlab/out/prompt_iq.csv        time_s, I_prompt, Q_prompt
%   matlab/out/prompt_iq_meta.json  parameters and computed indices
% ---------------------------------------------------------------------------

clc;

%% ---- configuration -------------------------------------------------------
cfg.PRNID           = 3;
cfg.SampleRate      = 10*1.023e6;   % must match fs in the waveform example
cfg.IntegrationTime = 1e-3;         % s -> 1 kHz prompt rate
cfg.CNo             = 45;           % dB-Hz

% Scintillation. Set ScintEnable = false for a clean NOMINAL reference.
cfg.ScintEnable    = true;
cfg.ScintRmsPhase  = 0.5;           % rad; ~1.0 gives S4 around 0.6

% Tracking loop settings. THESE ARE THE PARAMETERS NavIC-SIPS RECOMMENDS
% ADJUSTING — rerunning with different PLLNoiseBandwidth and counting
% loss-of-lock events is the project's headline KPI, measurable here with
% no silicon.
cfg.PLLOrder           = 2;
cfg.PLLNoiseBandwidth  = 18;
cfg.FLLOrder           = 1;
cfg.FLLNoiseBandwidth  = 4;
cfg.DLLOrder           = 1;
cfg.DLLNoiseBandwidth  = 1;

outDir = fullfile('matlab','out');
if ~exist(outDir,'dir'); mkdir(outDir); end

if ~exist('waveform','var')
    error(['No ''waveform'' in the workspace. Run the NavIC waveform ' ...
           'example first, then:  waveform = NavICBBWaveform;']);
end
waveform = waveform(:);   % force column

fprintf('NavIC-SIPS prompt I/Q extraction\n');
fprintf('  PRN %d, %d samples at %.3f MHz (%.2f s)\n', ...
        cfg.PRNID, numel(waveform), cfg.SampleRate/1e6, ...
        numel(waveform)/cfg.SampleRate);

%% ---- 1. scintillation channel --------------------------------------------
% MATLAB's HelperGNSSChannel does AWGN, delay and Doppler — NOT ionospheric
% scintillation. We generate it here with the same single-phase-screen model
% as python/golden/phase_screen.py so the two stay consistent.

if cfg.ScintEnable
    fprintf('  injecting scintillation, rms_phase = %.2f rad\n', ...
            cfg.ScintRmsPhase);
    fade = generateScintFade(numel(waveform), cfg.SampleRate, ...
                             cfg.ScintRmsPhase);
    rxWaveform = waveform .* fade(:);
else
    fprintf('  no scintillation (clean reference run)\n');
    rxWaveform = waveform;
end

% thermal noise at the requested C/No
%sigPower   = mean(abs(rxWaveform).^2);
%noisePower = sigPower / (10^(cfg.CNo/10) / cfg.SampleRate);
%rxWaveform = rxWaveform + sqrt(noisePower/2) * ...
             % (randn(size(rxWaveform)) + 1j*randn(size(rxWaveform)));

%% ---- 2. acquisition -------------------------------------------------------
fprintf('  acquiring...\n');

acquirer = gnssSignalAcquirer( ...
    'GNSSSignalType',        'navic l5 c/a', ...
    'SampleRate',             cfg.SampleRate, ...
    'IntermediateFrequency',  0);

nAcq = round(cfg.SampleRate * 2e-3);
[acqInfo, corrVal] = acquirer(rxWaveform(1:nAcq), cfg.PRNID);

disp('  acquirer returned:');
disp(acqInfo);

% If the field names below do not match what was just printed, edit them.
if ~acqInfo.IsDetected
    error(['Acquisition failed. Raise cfg.CNo, disable scintillation, ' ...
           'or lengthen the waveform.']);
end
fprintf('    detected: Doppler %.1f Hz, code phase %.1f\n', ...
        acqInfo.FrequencyOffset, acqInfo.CodePhaseOffset);

%% ---- 3. tracking — prompt I/Q is the FIRST output ------------------------
fprintf('  tracking...\n');

tracker = gnssSignalTracker( ...
    'GNSSSignalType',         'navic l5 c/a', ...
    'SampleRate',              cfg.SampleRate, ...
    'IntermediateFrequency',   0, ...
    'IntegrationTime',         cfg.IntegrationTime, ...
    'PRNID',                   cfg.PRNID, ...
    'InitialCodePhaseOffset',  acqInfo.CodePhaseOffset, ...
    'InitialFrequencyOffset',  acqInfo.FrequencyOffset, ...
    'PLLOrder',                cfg.PLLOrder, ...
    'PLLNoiseBandwidth',       cfg.PLLNoiseBandwidth, ...
    'FLLOrder',                cfg.FLLOrder, ...
    'FLLNoiseBandwidth',       cfg.FLLNoiseBandwidth, ...
    'DLLOrder',                cfg.DLLOrder, ...
    'DLLNoiseBandwidth',       cfg.DLLNoiseBandwidth);

[integWave, trackInfo] = tracker(rxWaveform);

% integWave IS the prompt correlator output: one complex sample per
% integration period. THIS IS THE SIGNAL NavIC-SIPS CONSUMES.
iPrompt = real(integWave(:));
qPrompt = imag(integWave(:));
nPrompt = numel(iPrompt);
promptRate = 1/cfg.IntegrationTime;

fprintf('    %d prompt samples at %.0f Hz\n', nPrompt, promptRate);

%% ---- 4. compute the indices, exactly as the SICU will --------------------
% Same arithmetic as python/golden/scint_indices.py. If these agree with the
% Python model on the same input, the golden model matches a real receiver.

intensity = iPrompt.^2 + qPrompt.^2;
meanI = mean(intensity);
S4    = sqrt(max(mean(intensity.^2)/(meanI^2) - 1, 0));
integWaveNoData = integWave(:).^2;  
phase = unwrap(angle(integWave(:).^2)) / 2;
idx   = (1:nPrompt)';
p     = polyfit(idx, phase, 1);
detrendedPhase = phase - polyval(p, idx);
sigmaPhi = std(detrendedPhase);

% NOTE: linear detrend here; the golden model uses a 0.1 Hz high-pass.
% TRACK A must confirm the conventional filter before either is final.

fprintf('\n  S4        = %.4f\n', S4);
fprintf('  sigma_phi = %.4f rad\n', sigmaPhi);

%% ---- 5. export ------------------------------------------------------------
t = (0:nPrompt-1)' / promptRate;

writetable(table(t, iPrompt, qPrompt, ...
                 'VariableNames', {'time_s','I_prompt','Q_prompt'}), ...
           fullfile(outDir,'prompt_iq.csv'));

meta = struct('PRNID', cfg.PRNID, ...
              'SampleRate_Hz', cfg.SampleRate, ...
              'IntegrationTime_s', cfg.IntegrationTime, ...
              'PromptRate_Hz', promptRate, ...
              'CNo_dBHz', cfg.CNo, ...
              'ScintEnable', cfg.ScintEnable, ...
              'ScintRmsPhase_rad', cfg.ScintRmsPhase, ...
              'PLLNoiseBandwidth_Hz', cfg.PLLNoiseBandwidth, ...
              'nPromptSamples', nPrompt, ...
              'S4', S4, ...
              'sigma_phi_rad', sigmaPhi, ...
              'note', ['Prompt I/Q from gnssSignalTracker first output. ' ...
                       'Post-correlation, not raw front-end.']);
fid = fopen(fullfile(outDir,'prompt_iq_meta.json'),'w');
fprintf(fid,'%s',jsonencode(meta,'PrettyPrint',true));
fclose(fid);

fprintf('  written: %s\n', fullfile(outDir,'prompt_iq.csv'));

%% ---- 6. plot --------------------------------------------------------------
figure('Name','NavIC-SIPS prompt I/Q');

subplot(3,1,1);
plot(t, iPrompt, t, qPrompt); grid on;
xlabel('time (s)'); ylabel('correlator output');
legend('I_{prompt}','Q_{prompt}');
title(sprintf('Prompt I/Q — PRN %d, S4 = %.3f', cfg.PRNID, S4));

subplot(3,1,2);
plot(t, intensity/meanI); grid on;
xlabel('time (s)'); ylabel('normalised intensity');
title('Intensity — this is what S4 measures');

subplot(3,1,3);
plot(t, detrendedPhase); grid on;
xlabel('time (s)'); ylabel('detrended phase (rad)');
title('Detrended carrier phase — this is what \sigma_\phi measures');

%% ==========================================================================
%  Local functions
%  ==========================================================================

function fade = generateScintFade(n, fs, rmsPhase)
% Single phase screen + Fresnel propagation. Mirrors
% python/golden/phase_screen.py.
%
% THE OUTER SCALE IS NOT OPTIONAL: without it all phase variance piles up at
% scales far larger than the Fresnel radius, Fresnel propagation filters
% them out, and S4 stays near zero no matter how large rmsPhase is. The
% (q^2 + q0^2)^(-p/2) form puts power where it actually diffracts.

    c      = 299792458;
    lambda = c / 1176.45e6;   % NavIC L5
    z      = 350e3;           % F-region screen height -- VERIFY (Track A)
    vDrift = 100;             % m/s zonal drift        -- VERIFY (Track A)
    p      = 3.0;             % spectral index         -- VERIFY (Track A)
    L0     = 1000;            % outer scale, m

    nfft = 2^nextpow2(n);
    dx   = vDrift / fs;

    % spatial frequency axis, wrapped to +/- Nyquist
    q = 2*pi * (0:nfft-1) / (nfft*dx);
    q(q > pi/dx) = q(q > pi/dx) - 2*pi/dx;
    q0 = 2*pi / L0;

    psd  = (q.^2 + q0^2).^(-p/2);
    spec = sqrt(psd) .* exp(1j*2*pi*rand(1,nfft));
    phi  = real(ifft(spec));
    phi  = phi / std(phi) * rmsPhase;

    k  = 2*pi/lambda;
    E  = ifft(fft(exp(1j*phi)) .* exp(-1j * q.^2 * z / (2*k)));

    fade = E(1:n);
    fade = fade / sqrt(mean(abs(fade).^2));   % preserve mean power
end
