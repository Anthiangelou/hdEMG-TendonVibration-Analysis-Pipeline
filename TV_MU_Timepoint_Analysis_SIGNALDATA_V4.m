%% TV_MU_Timepoint_Analysis_SIGNALDATA_V4.m
% Tendon-vibration MU analysis for MUedit edited MAT files.
%
% Supports two acquisition layouts automatically:
%   A) legacy files with signal.auxiliary
%   B) files with no signal.auxiliary, using:
%        TV trigger = signal.data channel 133
%        Force      = signal.data channel 130
%
% Requested epochs:
%   BeforeTV : up to 10 s immediately before TV onset; shorter windows are kept
%   immTV    : first usable 10 s immediately after TV onset
%   endTV    : last usable 10 s of the contraction/TV plateau
%
% Outputs per grid and epoch:
%   - MDR, CoV ISI, ISI metrics
%   - SD fCST and 1-s SD fCST
%   - force mean, SD and CoV
%   - Pearson SD-fCST vs force-CoV
%   - cross-correlation SD-fCST vs force-CoV (max, signed r, lag)
%   - original-style high-pass fCST vs force Pearson/cross-correlation
%   - individual MU spike times and binary MU x sample spike trains
%   - raster plots
%   - descriptive MDR and CoV-ISI plots with individual MU values + means
%
% IMPORTANT: for MATLAB-loaded v7.3 MUedit files signal.data is typically
% channels x samples, even though generic HDF5 readers may display the reversed
% dimension order. getDataChannel() handles either orientation.

clearvars;
close all;
clc;

%% -------------------------- USER SETTINGS -----------------------------
windowSec              = 10;
minUsableEpochSec      = 6;      % applies to immTV/endTV only
minSpikesPerMU         = 5;
minISIsPerOneSecBin    = 3;
triggerBaselineSec     = 2;
triggerMinRunSec       = 0.020;
fCSTHannSec            = 0.400;
highPassHz             = 0.75;
maxXCorrLagSec         = 2;

% Legacy auxiliary mapping (used only when signal.auxiliary exists)
forceAuxRow            = 13;
triggerAuxRow          = 4;
targetAuxRow           = 14;

% NEW mapping for files without signal.auxiliary
forceDataChannel       = 130;
triggerDataChannel     = 133;

makeQCPlots            = true;
makeSpikeRasterPlots   = true;
makeDescriptivePlots   = true;
writeExcel             = true;

% Optional overrides. Leave [] for automatic detection.
manualTVOnsetSec       = [];
manualPlateauStartSec  = [];
manualPlateauEndSec    = [];

%% ---------------------------- SELECT FILES ----------------------------
[fileNames,pathName] = uigetfile({'*edited.mat;*.mat','MUedit edited MAT (*.mat)'}, ...
    'Select edited MU files','MultiSelect','on');
if isequal(fileNames,0), return; end
if ischar(fileNames) || isstring(fileNames), fileNames = cellstr(fileNames); end

[outFile,outPath] = uiputfile('TV_MU_Timepoint_Results.xlsx','Save results workbook as');
if isequal(outFile,0), return; end
[~,outBase,~] = fileparts(outFile);
excelFile = fullfile(outPath,[outBase '.xlsx']);
matFile   = fullfile(outPath,[outBase '.mat']);

%% ----------------------- OUTPUT ACCUMULATORS --------------------------
summaryData = {};
muData      = {};
binData     = {};
spikeData   = {};
qcData      = {};

FullResults = repmat(struct( ...
    'File','', ...
    'ForceSource','', ...
    'TriggerSource','', ...
    'TVOnsetSample',[], ...
    'TVOnsetSec',[], ...
    'PlateauSamples',[], ...
    'CommonDecompCoverage',[], ...
    'Epochs',struct()),0,1);

summaryHeader = { ...
    'File','Grid','Epoch','Status','ForceSource','TriggerSource', ...
    'TV_Onset_s','PlateauStart_s','PlateauEnd_s','DecompStart_s','DecompEnd_s', ...
    'DesiredStart_s','DesiredEnd_s','ActualStart_s','ActualEnd_s','ActualDuration_s', ...
    'N_MUs_Total','N_MUs_Valid','Mean_MDR_Hz','SD_MDR_Hz', ...
    'Mean_CoV_ISI','Mean_CoV_ISI_pct','SD_CoV_ISI','SD_CoV_ISI_pct', ...
    'SD_fCST','Mean_fCST','Force_Mean','Force_SD','Force_CoV','Force_CoV_pct', ...
    'Pearson_SD_fCST_vs_ForceCoV_r','Pearson_SD_fCST_vs_ForceCoV_abs_r', ...
    'XCorr_SDfCST_ForceCoV_MaxAbs_r','XCorr_SDfCST_ForceCoV_AtMaxAbs_r', ...
    'XCorr_SDfCST_ForceCoV_Lag_s', ...
    'Mean_MU_CoVISI_vs_ForceCoV_r_Fisher','N_MUs_with_CoVISI_ForceCorr', ...
    'LegacyZeroLag_fCST_Force_r','LegacyZeroLag_fCST_Force_abs_r', ...
    'XCorr_fCST_Force_MaxAbs_r','XCorr_fCST_Force_AtMaxAbs_r','XCorr_fCST_Force_Lag_ms'};

muHeader = { ...
    'File','Grid','Epoch','MU_ID','N_Spikes','N_ISI','MDR_Hz', ...
    'MedianDR_Hz','MeanISI_ms','SD_ISI_ms','CoV_ISI','CoV_ISI_pct', ...
    'Pearson_1s_CoVISI_vs_ForceCoV_r', ...
    'Pearson_1s_CoVISI_vs_ForceCoV_abs_r','N_Valid_1s_Bins'};

binHeader = { ...
    'File','Grid','Epoch','Bin','BinStart_s','BinEnd_s', ...
    'ForceMean','ForceSD','ForceCoV','ForceCoV_pct','SD_fCST'};

spikeHeader = { ...
    'File','Grid','Epoch','MU_ID','Spike_Number','AbsoluteSample', ...
    'AbsoluteTime_s','EpochRelativeSample','EpochRelativeTime_s'};

qcHeader = { ...
    'File','ForceSource','TriggerSource','TV_Onset_s','TriggerPolarity', ...
    'TriggerPeakDeviation','PlateauStart_s','PlateauEnd_s', ...
    'Grid1_DecompStart_s','Grid1_DecompEnd_s','Grid2_DecompStart_s','Grid2_DecompEnd_s', ...
    'CommonDecompStart_s','CommonDecompEnd_s','BeforeTV_Status','immTV_Status','endTV_Status','Comment'};

%% =========================== FILE LOOP ================================
for fileIdx = 1:numel(fileNames)
    fileName = fileNames{fileIdx};
    fprintf('\nProcessing %s\n',fileName);
    S = load(fullfile(pathName,fileName));

    if ~isfield(S,'signal') || ~isfield(S,'edition')
        warning('%s skipped: signal or edition structure missing.',fileName);
        continue;
    end
    signal = S.signal;
    edition = S.edition;

    if isfield(signal,'fsamp')
        fs = double(signal.fsamp(1));
    else
        fs = 2048;
    end

    % Determine expected trial length before extracting signal.data channels.
    if isfield(signal,'target') && ~isempty(signal.target)
        expectedSamples = numel(signal.target);
    elseif isfield(edition,'time') && ~isempty(edition.time)
        expectedSamples = numel(edition.time);
    elseif isfield(signal,'data')
        expectedSamples = max(size(signal.data));
    else
        error('%s: cannot determine number of samples.',fileName);
    end

    %% Extract trigger and force using the correct file layout
    hasAux = isfield(signal,'auxiliary') && ~isempty(signal.auxiliary);
    if hasAux
        force = getAuxRow(signal.auxiliary,forceAuxRow,expectedSamples);
        trigger = getAuxRow(signal.auxiliary,triggerAuxRow,expectedSamples);
        forceSource = sprintf('signal.auxiliary(%d,:)',forceAuxRow);
        triggerSource = sprintf('signal.auxiliary(%d,:)',triggerAuxRow);
    else
        if ~isfield(signal,'data') || isempty(signal.data)
            error('%s: no signal.auxiliary and no signal.data.',fileName);
        end
        force = getDataChannel(signal.data,forceDataChannel,expectedSamples);
        trigger = getDataChannel(signal.data,triggerDataChannel,expectedSamples);
        forceSource = sprintf('signal.data channel %d',forceDataChannel);
        triggerSource = sprintf('signal.data channel %d',triggerDataChannel);
    end

    force = double(force(:)');
    trigger = double(trigger(:)');
    nSamples = min(numel(force),numel(trigger));
    force = force(1:nSamples);
    trigger = trigger(1:nSamples);
    timeSec = (0:nSamples-1)/fs;

    % Preserve original sign/offset handling.
    if mean(force(1:min(1000,end)),'omitnan') > median(force,'omitnan')
        force = -force;
    end
    forceOffset = mean(force(1:min(100,end)),'omitnan');
    force = force-forceOffset;

    %% TV onset
    if isempty(manualTVOnsetSec)
        [tvOnset,trigInfo] = detectTVOnset(trigger,fs,triggerBaselineSec,triggerMinRunSec);
    else
        tvOnset = max(1,min(nSamples,round(manualTVOnsetSec*fs)+1));
        trigInfo = struct('polarity',"manual",'peakDeviation',NaN);
    end

    %% Contraction plateau bounds
    if ~isempty(manualPlateauStartSec) && ~isempty(manualPlateauEndSec)
        plateauStart = max(1,round(manualPlateauStartSec*fs)+1);
        plateauEnd = min(nSamples,round(manualPlateauEndSec*fs)+1);
    elseif hasAux && sizeAlongSamples(signal.auxiliary,expectedSamples) >= targetAuxRow
        % Legacy files: retain the auxiliary target-based method.
        target = getAuxRow(signal.auxiliary,targetAuxRow,expectedSamples);
        [plateauStart,plateauEnd] = detectTargetPlateau(double(target(:)'),fs);
    else
        % New signal.data files: signal.target is not assumed to be equivalent
        % to the old auxiliary target. Use measured force to exclude ramp-up
        % and any clear ramp-down.
        [plateauStart,plateauEnd] = detectForcePlateau(force,fs,tvOnset);
    end

    plateauStart = max(1,min(nSamples,plateauStart));
    plateauEnd = max(plateauStart,min(nSamples,plateauEnd));

    %% MU discharge trains and coverage
    nGrids = min(2,size(edition.Dischargetimes,1));
    gridPulses = cell(1,nGrids);
    gridStart = nan(1,nGrids);
    gridEnd = nan(1,nGrids);
    for g = 1:nGrids
        gridPulses{g} = cleanPulseCells(edition.Dischargetimes(g,:),nSamples);
        [gridStart(g),gridEnd(g)] = pulseCoverage(gridPulses{g});
    end

    validStarts = gridStart(isfinite(gridStart));
    validEnds = gridEnd(isfinite(gridEnd));
    if isempty(validStarts) || isempty(validEnds)
        commonDecompStart = 1;
        commonDecompEnd = nSamples;
        decompComment = 'No valid MU discharge times found.';
    else
        commonDecompStart = max(validStarts);
        commonDecompEnd = min(validEnds);
        decompComment = '';
    end

    %% Epoch definitions
    desiredBefore = [tvOnset-round(windowSec*fs), tvOnset-1];
    desiredImm = [tvOnset, tvOnset+round(windowSec*fs)-1];
    usableEndAnchor = min([nSamples,plateauEnd,commonDecompEnd]);
    desiredEnd = [usableEndAnchor-round(windowSec*fs)+1,usableEndAnchor];

    desiredEpochs = [desiredBefore; desiredImm; desiredEnd];
    epochNames = {'BeforeTV','immTV','endTV'};
    actualEpochs = nan(3,2);
    epochStatus = strings(3,1);

    for e = 1:3
        ds = max(1,desiredEpochs(e,1));
        de = min(nSamples,desiredEpochs(e,2));
        desiredDur = max(0,(de-ds+1)/fs);

        if e == 1
            % BeforeTV is included even when <10 s. Do not constrain by common
            % MU coverage; each MU's actual spikes are handled independently.
            as = max(ds,plateauStart);
            ae = min(de,plateauEnd);
        else
            as = max([ds,plateauStart,commonDecompStart]);
            ae = min([de,plateauEnd,commonDecompEnd]);
        end

        actualEpochs(e,:) = [as ae];
        if ae < as
            epochStatus(e) = "INVALID_NO_USABLE_SAMPLES";
        else
            actualDur = (ae-as+1)/fs;
            if e == 1
                if actualDur < desiredDur-1/fs
                    epochStatus(e) = "SHORTENED_BEFORE_TV_INCLUDED";
                else
                    epochStatus(e) = "OK";
                end
            elseif actualDur < minUsableEpochSec
                epochStatus(e) = "INVALID_INSUFFICIENT_USABLE_DATA";
            elseif actualDur < desiredDur-1/fs
                epochStatus(e) = "SHORTENED_TO_VALID_PLATEAU";
            else
                epochStatus(e) = "OK";
            end
        end
    end

    %% QC row
    g1s=NaN; g1e=NaN; g2s=NaN; g2e=NaN;
    if nGrids>=1, g1s=sample2sec(gridStart(1),fs); g1e=sample2sec(gridEnd(1),fs); end
    if nGrids>=2, g2s=sample2sec(gridStart(2),fs); g2e=sample2sec(gridEnd(2),fs); end
    qcComment = decompComment;
    if epochStatus(1)=="SHORTENED_BEFORE_TV_INCLUDED"
        qcComment = strtrim(sprintf('%s BeforeTV included at shorter-than-10-s duration.',qcComment));
    end

    qcData(end+1,:) = {fileName,forceSource,triggerSource,sample2sec(tvOnset,fs), ...
        char(trigInfo.polarity),trigInfo.peakDeviation,sample2sec(plateauStart,fs), ...
        sample2sec(plateauEnd,fs),g1s,g1e,g2s,g2e,sample2sec(commonDecompStart,fs), ...
        sample2sec(commonDecompEnd,fs),char(epochStatus(1)),char(epochStatus(2)), ...
        char(epochStatus(3)),qcComment}; %#ok<SAGROW>

    %% QC plot
    if makeQCPlots
        fig = figure('Visible','off','Color','w','Name',['TV epochs - ' fileName], ...
            'Position',[80 80 1400 800]);
        ax1=subplot(2,1,1); hold(ax1,'on');
        plot(ax1,timeSec,force,'k','LineWidth',0.8);
        yl=ylim(ax1); addEpochPatches(ax1,actualEpochs,epochStatus,fs,yl);
        xline(ax1,sample2sec(tvOnset,fs),'--','TV onset','LineWidth',1.5);
        xline(ax1,sample2sec(plateauStart,fs),':','plateau start');
        xline(ax1,sample2sec(plateauEnd,fs),':','plateau end');
        ylabel(ax1,'Force'); title(ax1,strrep(fileName,'_','\_')); grid(ax1,'on');

        ax2=subplot(2,1,2); hold(ax2,'on');
        plot(ax2,timeSec,trigger,'Color',[0.2 0.2 0.2]);
        xline(ax2,sample2sec(tvOnset,fs),'--','TV onset','LineWidth',1.5);
        ylabel(ax2,'TV trigger'); xlabel(ax2,'Time (s)'); grid(ax2,'on');
        linkaxes([ax1 ax2],'x');
        exportgraphics(fig,fullfile(outPath,[outBase '_' sanitizeFilename(fileName) '_QC.png']),'Resolution',180);
        close(fig);
    end

    %% Full-trial fCST per grid
    fullFCST = cell(1,nGrids);
    totalMU = zeros(1,nGrids);
    for g=1:nGrids
        validMU=find(~cellfun(@isempty,gridPulses{g}));
        totalMU(g)=numel(validMU);
        if isempty(validMU)
            fullFCST{g}=nan(1,nSamples);
        else
            [~,fullFCST{g}] = calcCSTsafe(gridPulses{g}(validMU),fs,nSamples,fCSTHannSec);
        end
    end

    %% Result shell
    fileResult = struct();
    fileResult.File = fileName;
    fileResult.ForceSource = forceSource;
    fileResult.TriggerSource = triggerSource;
    fileResult.TVOnsetSample = tvOnset;
    fileResult.TVOnsetSec = sample2sec(tvOnset,fs);
    fileResult.PlateauSamples = [plateauStart plateauEnd];
    fileResult.CommonDecompCoverage = [commonDecompStart commonDecompEnd];
    fileResult.Epochs = struct();

    %% -------------------------- EPOCH LOOP -----------------------------
    for e=1:3
        epochName=epochNames{e};
        as=actualEpochs(e,1); ae=actualEpochs(e,2); status=epochStatus(e);
        desiredStartSec=sample2sec(max(1,desiredEpochs(e,1)),fs);
        desiredEndSec=sample2sec(min(nSamples,desiredEpochs(e,2)),fs);

        if startsWith(status,"INVALID_") || ae<as
            for g=1:nGrids
                summaryData(end+1,:) = invalidSummaryRow(summaryHeader,fileName,g,epochName,status, ...
                    forceSource,triggerSource,tvOnset,plateauStart,plateauEnd,commonDecompStart, ...
                    commonDecompEnd,desiredStartSec,desiredEndSec,as,ae,fs,totalMU(g)); %#ok<SAGROW>
            end
            fileResult.Epochs.(epochName).Status=char(status);
            fileResult.Epochs.(epochName).Samples=[as ae];
            continue;
        end

        idx=as:ae;
        actualDuration=numel(idx)/fs;
        forceEpoch=force(idx);
        detrendedForce=detrend(forceEpoch,2)+mean(forceEpoch,'omitnan');
        forceMean=mean(forceEpoch,'omitnan');
        forceSD=std(forceEpoch,0,'omitnan');
        forceCoV=safeDivide(forceSD,abs(forceMean));

        nOneSecBins=floor(numel(idx)/fs);
        forceMean1s=nan(1,nOneSecBins); forceSD1s=nan(1,nOneSecBins); forceCoV1s=nan(1,nOneSecBins);
        for bidx=1:nOneSecBins
            ls=(bidx-1)*fs+1; le=bidx*fs;
            fw=detrendedForce(ls:le);
            forceMean1s(bidx)=mean(fw,'omitnan');
            forceSD1s(bidx)=std(fw,0,'omitnan');
            forceCoV1s(bidx)=safeDivide(forceSD1s(bidx),abs(forceMean1s(bidx)));
        end

        epochResult=struct();
        epochResult.Status=char(status);
        epochResult.Samples=[as ae];
        epochResult.TimeSec=[sample2sec(as,fs) sample2sec(ae,fs)];
        epochResult.Force=struct('Mean',forceMean,'SD',forceSD,'CoV',forceCoV, ...
            'Mean1s',forceMean1s,'SD1s',forceSD1s,'CoV1s',forceCoV1s);

        for g=1:nGrids
            pulsesThisGrid=gridPulses{g};
            fCSTEpoch=fullFCST{g}(idx);
            detrendedFCST=detrend(fCSTEpoch,2)+mean(fCSTEpoch,'omitnan');
            sdFCST=std(detrendedFCST,0,'omitnan');
            meanFCST=mean(fCSTEpoch,'omitnan');

            sdFCST1s=nan(1,nOneSecBins);
            for bidx=1:nOneSecBins
                ls=(bidx-1)*fs+1; le=bidx*fs;
                cw=detrendedFCST(ls:le);
                sdFCST1s(bidx)=std(cw,0,'omitnan');
                binAbsStart=as+ls-1; binAbsEnd=as+le-1;
                binData(end+1,:)={fileName,g,epochName,bidx,sample2sec(binAbsStart,fs), ...
                    sample2sec(binAbsEnd,fs),forceMean1s(bidx),forceSD1s(bidx), ...
                    forceCoV1s(bidx),100*forceCoV1s(bidx),sdFCST1s(bidx)}; %#ok<SAGROW>
            end

            % SD-fCST versus force CoV (Pearson + cross-correlation)
            rSDfCSTForce=pairCorr(sdFCST1s,forceCoV1s);
            rSDfCSTForceAbs=abs(rSDfCSTForce);
            maxVarLagBins=min(round(maxXCorrLagSec),max(0,nOneSecBins-2));
            [varXC,varLags,varXCMaxAbs,varXCAtMax,varXCLagBins] = ...
                crossCorrSummary(sdFCST1s,forceCoV1s,maxVarLagBins);
            varXCLagSec=varXCLagBins; % 1 point = 1 second

            % Original-style high-pass fCST versus force correlation
            if numel(fCSTEpoch)>3*fs && all(isfinite(fCSTEpoch))
                [bhp,ahp]=butter(4,highPassHz/(0.5*fs),'high');
                hpFCST=filtfilt(bhp,ahp,detrendedFCST);
                legacyR=pairCorr(hpFCST,forceEpoch);
                legacyAbsR=abs(legacyR);
                x=hpFCST-mean(hpFCST,'omitnan');
                y=forceEpoch-mean(forceEpoch,'omitnan');
                maxLag=min(round(maxXCorrLagSec*fs),numel(x)-2);
                [xc,lags,xcMaxAbs,xcAtMax,xcLagSamples]=crossCorrSummary(x,y,maxLag);
                xcLagMs=1000*xcLagSamples/fs;
            else
                hpFCST=[]; legacyR=NaN; legacyAbsR=NaN;
                xc=[]; lags=[]; xcMaxAbs=NaN; xcAtMax=NaN; xcLagMs=NaN;
            end

            %% MU spike trains and discharge metrics
            nMUGrid=numel(pulsesThisGrid);
            spikeTrainBinary=sparse(nMUGrid,numel(idx));
            spikeTimesAbsSamples=cell(1,nMUGrid);
            spikeTimesAbsSec=cell(1,nMUGrid);
            spikeTimesRelSamples=cell(1,nMUGrid);
            spikeTimesRelSec=cell(1,nMUGrid);

            mdr=nan(1,nMUGrid); meddr=nan(1,nMUGrid); covisi=nan(1,nMUGrid);
            meanisi=nan(1,nMUGrid); sdisi=nan(1,nMUGrid);
            nsp=zeros(1,nMUGrid); nrISI=zeros(1,nMUGrid);
            rMUForce=nan(1,nMUGrid); nCorrBins=zeros(1,nMUGrid);
            covISI1sAll=cell(1,nMUGrid);

            for mu=1:nMUGrid
                pAll=pulsesThisGrid{mu};
                if isempty(pAll), continue; end
                p=pAll(pAll>=as & pAll<=ae);
                nsp(mu)=numel(p);

                if ~isempty(p)
                    relSamples=p-as+1;
                    spikeTrainBinary(mu,relSamples)=1;
                    spikeTimesAbsSamples{mu}=p;
                    spikeTimesAbsSec{mu}=(p-1)/fs;
                    spikeTimesRelSamples{mu}=relSamples;
                    spikeTimesRelSec{mu}=(relSamples-1)/fs;
                    for sp=1:numel(p)
                        spikeData(end+1,:)={fileName,g,epochName,mu,sp,p(sp),sample2sec(p(sp),fs), ...
                            relSamples(sp),(relSamples(sp)-1)/fs}; %#ok<SAGROW>
                    end
                end

                if numel(p)>=minSpikesPerMU
                    isiSamples=diff(p); isiSec=isiSamples/fs; nrISI(mu)=numel(isiSec);
                    dr=1./isiSec;
                    mdr(mu)=mean(dr,'omitnan'); meddr(mu)=median(dr,'omitnan');
                    meanisi(mu)=1000*mean(isiSec,'omitnan');
                    sdisi(mu)=1000*std(isiSec,0,'omitnan');
                    covisi(mu)=safeDivide(std(isiSec,0,'omitnan'),mean(isiSec,'omitnan'));

                    tISI=p(1:end-1);
                    cov1s=nan(1,nOneSecBins);
                    for bidx=1:nOneSecBins
                        bs=as+(bidx-1)*fs; be=bs+fs-1;
                        vals=isiSec(tISI>=bs & tISI<=be);
                        if numel(vals)>=minISIsPerOneSecBin
                            cov1s(bidx)=safeDivide(std(vals,0,'omitnan'),mean(vals,'omitnan'));
                        end
                    end
                    covISI1sAll{mu}=cov1s;
                    validPair=isfinite(cov1s)&isfinite(forceCoV1s);
                    nCorrBins(mu)=sum(validPair);
                    if nCorrBins(mu)>=3
                        rMUForce(mu)=pairCorr(cov1s,forceCoV1s);
                    end
                end

                muData(end+1,:)={fileName,g,epochName,mu,nsp(mu),nrISI(mu),mdr(mu),meddr(mu), ...
                    meanisi(mu),sdisi(mu),covisi(mu),100*covisi(mu),rMUForce(mu), ...
                    abs(rMUForce(mu)),nCorrBins(mu)}; %#ok<SAGROW>
            end

            validMU=isfinite(mdr)&isfinite(covisi);
            nValidMU=sum(validMU);
            meanMDR=mean(mdr(validMU),'omitnan'); sdMDR=std(mdr(validMU),0,'omitnan');
            meanCoVISI=mean(covisi(validMU),'omitnan'); sdCoVISI=std(covisi(validMU),0,'omitnan');
            validR=isfinite(rMUForce); nValidR=sum(validR); meanMUcorr=fisherMean(rMUForce(validR));

            summaryData(end+1,:)={fileName,g,epochName,char(status),forceSource,triggerSource, ...
                sample2sec(tvOnset,fs),sample2sec(plateauStart,fs),sample2sec(plateauEnd,fs), ...
                sample2sec(commonDecompStart,fs),sample2sec(commonDecompEnd,fs), ...
                desiredStartSec,desiredEndSec,sample2sec(as,fs),sample2sec(ae,fs),actualDuration, ...
                totalMU(g),nValidMU,meanMDR,sdMDR,meanCoVISI,100*meanCoVISI,sdCoVISI,100*sdCoVISI, ...
                sdFCST,meanFCST,forceMean,forceSD,forceCoV,100*forceCoV, ...
                rSDfCSTForce,rSDfCSTForceAbs,varXCMaxAbs,varXCAtMax,varXCLagSec, ...
                meanMUcorr,nValidR,legacyR,legacyAbsR,xcMaxAbs,xcAtMax,xcLagMs}; %#ok<SAGROW>

            gridResult=struct();
            gridResult.MU_ID=1:nMUGrid;
            gridResult.NSpikes=nsp;
            gridResult.MDR_Hz=mdr;
            gridResult.MedianDR_Hz=meddr;
            gridResult.CoV_ISI=covisi;
            gridResult.MeanISI_ms=meanisi;
            gridResult.SD_ISI_ms=sdisi;
            gridResult.CoV_ISI_1s=covISI1sAll;
            gridResult.Corr_CoVISI1s_ForceCoV1s=rMUForce;
            gridResult.SpikeTimesSamplesAbsolute=spikeTimesAbsSamples;
            gridResult.SpikeTimesSecAbsolute=spikeTimesAbsSec;
            gridResult.SpikeTimesSamplesEpochRelative=spikeTimesRelSamples;
            gridResult.SpikeTimesSecEpochRelative=spikeTimesRelSec;
            gridResult.SpikeTrainBinary=spikeTrainBinary;
            gridResult.CST_RawEpoch=full(sum(spikeTrainBinary,1));
            gridResult.fCST=fCSTEpoch;
            gridResult.Detrended_fCST=detrendedFCST;
            gridResult.SD_fCST=sdFCST;
            gridResult.SD_fCST_1s=sdFCST1s;
            gridResult.Corr_SDfCST1s_ForceCoV1s=rSDfCSTForce;
            gridResult.CorrAbs_SDfCST1s_ForceCoV1s=rSDfCSTForceAbs;
            gridResult.XCorr_SDfCST1s_ForceCoV1s=varXC;
            gridResult.XCorr_SDfCST1s_ForceCoV1s_Lags_s=varLags;
            gridResult.XCorr_SDfCST1s_ForceCoV1s_MaxAbs=varXCMaxAbs;
            gridResult.XCorr_SDfCST1s_ForceCoV1s_AtMax=varXCAtMax;
            gridResult.XCorr_SDfCST1s_ForceCoV1s_Lag_s=varXCLagSec;
            gridResult.HighPassed_fCST=hpFCST;
            gridResult.LegacyZeroLag_fCST_Force_r=legacyR;
            gridResult.XCorr_fCST_Force=xc;
            gridResult.XCorr_fCST_Force_Lags_ms=1000*lags/fs;
            gridResult.XCorrMaxAbs=xcMaxAbs;
            gridResult.XCorrAtMax=xcAtMax;
            gridResult.XCorrLag_ms=xcLagMs;
            epochResult.(sprintf('Grid%d',g))=gridResult;
        end

        if makeSpikeRasterPlots
            saveSpikeRasterFigure(epochResult,nGrids,fileName,epochName, ...
                sample2sec(as,fs),sample2sec(ae,fs),sample2sec(tvOnset,fs),outPath,outBase);
        end
        fileResult.Epochs.(epochName)=epochResult;
    end

    if makeDescriptivePlots
        saveMUDescriptivePlots(fileResult,nGrids,fileName,outPath,outBase);
    end

    FullResults(end+1,1)=fileResult; %#ok<SAGROW>
end

%% ------------------------------- EXPORT -------------------------------
SummaryTable=cell2table(summaryData,'VariableNames',summaryHeader);
MUDetailTable=cell2table(muData,'VariableNames',muHeader);
OneSecondTable=cell2table(binData,'VariableNames',binHeader);
MUSpikeTable=cell2table(spikeData,'VariableNames',spikeHeader);
QCTable=cell2table(qcData,'VariableNames',qcHeader);

if writeExcel
    if exist(excelFile,'file'), delete(excelFile); end
    writetable(SummaryTable,excelFile,'Sheet','Epoch_Summary');
    writetable(MUDetailTable,excelFile,'Sheet','MU_Details');
    writetable(OneSecondTable,excelFile,'Sheet','OneSecond_Data');
    writetable(MUSpikeTable,excelFile,'Sheet','MU_Spikes');
    writetable(QCTable,excelFile,'Sheet','QC');
end
save(matFile,'FullResults','SummaryTable','MUDetailTable','OneSecondTable','MUSpikeTable','QCTable','-v7.3');
fprintf('\nAnalysis complete.\nExcel: %s\nMAT: %s\n',excelFile,matFile);

%% =========================== LOCAL FUNCTIONS ==========================
function x=getAuxRow(aux,row,expectedSamples)
    if size(aux,2)==expectedSamples && size(aux,1)>=row
        x=aux(row,:);
    elseif size(aux,1)==expectedSamples && size(aux,2)>=row
        x=aux(:,row)';
    elseif size(aux,1)>=row && size(aux,2)>size(aux,1)
        x=aux(row,:);
    elseif size(aux,2)>=row
        x=aux(:,row)';
    else
        error('Auxiliary row %d not found.',row);
    end
end

function nCh=sizeAlongSamples(data,expectedSamples)
    if size(data,2)==expectedSamples
        nCh=size(data,1);
    elseif size(data,1)==expectedSamples
        nCh=size(data,2);
    else
        nCh=min(size(data));
    end
end

function x=getDataChannel(data,ch,expectedSamples)
    % Handles either channels x samples or samples x channels.
    if size(data,2)==expectedSamples && size(data,1)>=ch
        x=data(ch,:);
    elseif size(data,1)==expectedSamples && size(data,2)>=ch
        x=data(:,ch)';
    elseif size(data,1)>=ch && size(data,2)>size(data,1)
        x=data(ch,:);
    elseif size(data,2)>=ch && size(data,1)>size(data,2)
        x=data(:,ch)';
    else
        error('signal.data channel %d cannot be extracted from size %dx%d.',ch,size(data,1),size(data,2));
    end
end

function [onset,info]=detectTVOnset(trigger,fs,baselineSec,minRunSec)
    x=double(trigger(:)');
    nBase=min(numel(x),max(10,round(baselineSec*fs)));
    base=median(x(1:nBase),'omitnan');
    bdev=x(1:nBase)-base;
    robustSigma=1.4826*median(abs(bdev-median(bdev,'omitnan')),'omitnan');
    if ~isfinite(robustSigma)||robustSigma<=eps, robustSigma=std(bdev,0,'omitnan'); end
    if ~isfinite(robustSigma)||robustSigma<=eps, robustSigma=eps; end
    dev=abs(x-base); threshold=8*robustSigma; above=dev>threshold;
    d=diff([false above false]); rs=find(d==1); re=find(d==-1)-1;
    minRun=max(1,round(minRunSec*fs)); keep=(re-rs+1)>=minRun & re>nBase;
    rs=rs(keep); re=re(keep);
    if isempty(rs)
        [peakDev,rel]=max(dev(nBase+1:end)); onset=nBase+rel; peakIndex=onset;
    else
        score=zeros(size(rs));
        for k=1:numel(rs), score(k)=sum(dev(rs(k):re(k)),'omitnan'); end
        [~,best]=max(score); onset=rs(best);
        [peakDev,rel]=max(dev(rs(best):re(best))); peakIndex=rs(best)+rel-1;
    end
    if x(peakIndex)-base>=0, polarity="positive"; else, polarity="negative"; end
    info=struct('baseline',base,'threshold',threshold,'polarity',polarity, ...
        'peakDeviation',peakDev,'peakIndex',peakIndex);
end

function [plateauStart,plateauEnd]=detectForcePlateau(force,fs,tvOnset)
    % Robust fallback for files without the old auxiliary target channel.
    x=double(force(:)'); n=numel(x);
    y=movmean(x,max(3,round(0.25*fs)),'omitnan');
    nBase=min(n,max(10,round(2*fs)));
    base=median(y(1:nBase),'omitnan');

    a0=min(n,max(1,tvOnset+round(2*fs)));
    a1=min(n,max(a0,tvOnset+round(12*fs)));
    active=median(y(a0:a1),'omitnan');
    amp=active-base;
    if ~isfinite(amp)||abs(amp)<=eps
        plateauStart=1; plateauEnd=n; return;
    end
    progress=(y-base)/amp;

    % Ramp-up excluded at first sustained 80% of active level.
    mask=progress>=0.80;
    [rs,re]=logicalRuns(mask);
    keep=(re-rs+1)>=round(1*fs);
    rs=rs(keep); re=re(keep);
    if isempty(rs)
        plateauStart=1;
    else
        preOrNear=find(rs<=tvOnset,1,'first');
        if isempty(preOrNear), plateauStart=rs(1); else, plateauStart=rs(preOrNear); end
    end

    % A true ramp-down should fall below 50% active level for >=0.5 s.
    % Fatigue-related drift usually remains above this and is retained.
    after=(1:n)>=min(n,tvOnset+round(5*fs));
    down=(progress<=0.50)&after;
    [ds,de]=logicalRuns(down);
    keep=(de-ds+1)>=round(0.5*fs);
    ds=ds(keep);
    if isempty(ds), plateauEnd=n; else, plateauEnd=max(plateauStart,ds(1)-1); end
end

function [s,e]=logicalRuns(mask)
    d=diff([false logical(mask) false]); s=find(d==1); e=find(d==-1)-1;
end

function [plateauStart,plateauEnd]=detectTargetPlateau(target,fs)
    x=double(target(:)');
    if numel(x)<fs, plateauStart=1; plateauEnd=numel(x); return; end
    y=movmedian(x,max(3,round(0.20*fs)),'omitnan');
    base=median(y(1:min(round(2*fs),end)),'omitnan');
    lo=prctile(y,5); hi=prctile(y,95);
    if abs(hi-base)>=abs(lo-base), plateauLevel=hi; else, plateauLevel=lo; end
    amp=plateauLevel-base;
    if ~isfinite(amp)||abs(amp)<eps, plateauStart=1; plateauEnd=numel(x); return; end
    progress=(y-base)/amp; onPlateau=progress>=0.95;
    [rs,re]=logicalRuns(onPlateau); dur=re-rs+1; keep=dur>=round(1*fs);
    rs=rs(keep); re=re(keep); dur=dur(keep);
    if isempty(rs), plateauStart=1; plateauEnd=numel(x); else, [~,ii]=max(dur); plateauStart=rs(ii); plateauEnd=re(ii); end
end

function pulses=cleanPulseCells(pulses,nSamples)
    if ~iscell(pulses), pulses=num2cell(pulses,2); end
    for k=1:numel(pulses)
        p=double(pulses{k}); p=round(p(:)');
        p=p(isfinite(p)&p>=1&p<=nSamples); pulses{k}=unique(p,'stable');
    end
end

function [s,e]=pulseCoverage(pulses)
    firsts=nan(1,numel(pulses)); lasts=nan(1,numel(pulses));
    for k=1:numel(pulses)
        if ~isempty(pulses{k}), firsts(k)=pulses{k}(1); lasts(k)=pulses{k}(end); end
    end
    if any(isfinite(firsts)), s=min(firsts,[],'omitnan'); e=max(lasts,[],'omitnan'); else, s=NaN; e=NaN; end
end

function [cst,filtCST]=calcCSTsafe(MUPulses,fs,sigLen,hannSec)
    pad=2000; allSpikes=[];
    for k=1:numel(MUPulses)
        p=round(double(MUPulses{k}(:))); p=p(p>=1&p<=sigLen);
        allSpikes=[allSpikes;p]; %#ok<AGROW>
    end
    paddedLen=sigLen+2*pad; cstPadded=zeros(paddedLen,1);
    if ~isempty(allSpikes), cstPadded=accumarray(allSpikes+pad,1,[paddedLen 1]); end
    win=hann(max(3,round(hannSec*fs))); win=win/sum(win);
    filtPadded=filtfilt(win,1,cstPadded);
    cst=cstPadded(pad+1:pad+sigLen)'; filtCST=filtPadded(pad+1:pad+sigLen)';
    cst=cst-mean(cst,'omitnan');
end

function r=pairCorr(x,y)
    x=x(:); y=y(:); keep=isfinite(x)&isfinite(y); x=x(keep); y=y(keep);
    if numel(x)<3||std(x)==0||std(y)==0, r=NaN; return; end
    C=corrcoef(x,y); r=C(1,2);
end

function [xc,lags,maxAbsR,atMaxR,lagAtMax]=crossCorrSummary(x,y,maxLag)
    x=double(x(:)); y=double(y(:)); keep=isfinite(x)&isfinite(y); x=x(keep); y=y(keep);
    if nargin<3||isempty(maxLag), maxLag=numel(x)-2; end
    maxLag=min(max(0,round(maxLag)),max(0,numel(x)-2));
    if numel(x)<3||std(x)==0||std(y)==0
        xc=[]; lags=[]; maxAbsR=NaN; atMaxR=NaN; lagAtMax=NaN; return;
    end
    x=x-mean(x,'omitnan'); y=y-mean(y,'omitnan');
    [xc,lags]=xcorr(x,y,maxLag,'coeff');
    [maxAbsR,ii]=max(abs(xc)); atMaxR=xc(ii); lagAtMax=lags(ii);
end

function out=fisherMean(r)
    r=r(isfinite(r)); if isempty(r), out=NaN; return; end
    r=max(min(r,0.999999),-0.999999); out=tanh(mean(atanh(r)));
end

function y=safeDivide(a,b)
    if ~isfinite(a)||~isfinite(b)||abs(b)<=eps, y=NaN; else, y=a/b; end
end

function sec=sample2sec(sample,fs)
    if isempty(sample)||~isfinite(sample), sec=NaN; else, sec=(sample-1)/fs; end
end

function row=invalidSummaryRow(header,fileName,g,epochName,status,forceSource,triggerSource, ...
    tvOnset,plateauStart,plateauEnd,decompStart,decompEnd,desiredStartSec,desiredEndSec,as,ae,fs,nTotalMU)
    row=repmat({NaN},1,numel(header));
    if ae>=as, dur=(ae-as+1)/fs; asSec=sample2sec(as,fs); aeSec=sample2sec(ae,fs); else, dur=0; asSec=NaN; aeSec=NaN; end
    row{1}=fileName; row{2}=g; row{3}=epochName; row{4}=char(status);
    row{5}=forceSource; row{6}=triggerSource; row{7}=sample2sec(tvOnset,fs);
    row{8}=sample2sec(plateauStart,fs); row{9}=sample2sec(plateauEnd,fs);
    row{10}=sample2sec(decompStart,fs); row{11}=sample2sec(decompEnd,fs);
    row{12}=desiredStartSec; row{13}=desiredEndSec; row{14}=asSec; row{15}=aeSec; row{16}=dur;
    row{17}=nTotalMU; row{18}=0; row{37}=0; % N MUs with valid CoV-ISI/force correlation
end

function addEpochPatches(ax,epochs,status,fs,yl)
    labels={'BeforeTV','immTV','endTV'};
    for k=1:3
        s=epochs(k,1); e=epochs(k,2); if ~isfinite(s)||~isfinite(e)||e<s, continue; end
        x1=sample2sec(s,fs); x2=sample2sec(e,fs);
        alpha=0.10; if startsWith(status(k),"INVALID_"), alpha=0.05; end
        patch(ax,[x1 x2 x2 x1],[yl(1) yl(1) yl(2) yl(2)],[0.5 0.5 0.5], ...
            'FaceAlpha',alpha,'EdgeColor','none','HandleVisibility','off');
        text(ax,(x1+x2)/2,yl(2),labels{k},'HorizontalAlignment','center','VerticalAlignment','top','FontWeight','bold');
    end
end

function saveSpikeRasterFigure(epochResult,nGrids,fileName,epochName,tStart,tEnd,tvSec,outPath,outBase)
    fig=figure('Visible','off','Color','w','Position',[100 100 1400 max(450,320*nGrids)]);
    for g=1:nGrids
        ax=subplot(nGrids,1,g); hold(ax,'on'); fld=sprintf('Grid%d',g);
        if ~isfield(epochResult,fld), continue; end
        spikeCells=epochResult.(fld).SpikeTimesSecAbsolute; plotted=false;
        for mu=1:numel(spikeCells)
            t=spikeCells{mu}; if isempty(t), continue; end; plotted=true;
            for k=1:numel(t), line(ax,[t(k) t(k)],[mu-0.35 mu+0.35],'Color','k','LineWidth',0.8); end
        end
        if tvSec>=tStart&&tvSec<=tEnd, xline(ax,tvSec,'--','TV onset','LineWidth',1.2); end
        xlim(ax,[tStart tEnd]); ylim(ax,[0.5 max(1.5,numel(spikeCells)+0.5)]);
        ylabel(ax,sprintf('Grid %d MU',g)); grid(ax,'on');
        if ~plotted, text(ax,mean([tStart tEnd]),max(1,numel(spikeCells))/2,'No MU spikes in this epoch','HorizontalAlignment','center'); end
        if g==1, title(ax,sprintf('%s | %s | %.2f-%.2f s',strrep(fileName,'_','\_'),epochName,tStart,tEnd)); end
        if g==nGrids, xlabel(ax,'Time (s)'); end
    end
    exportgraphics(fig,fullfile(outPath,[outBase '_' sanitizeFilename(fileName) '_' epochName '_SpikeTrains.png']),'Resolution',180);
    close(fig);
end

function saveMUDescriptivePlots(fileResult,nGrids,fileName,outPath,outBase)
    epochNames={'BeforeTV','immTV','endTV'}; epochLabels={'Before TV','Immediate TV','End TV'};
    fig=figure('Visible','off','Color','w','Position',[80 80 1500 max(650,420*nGrids)]);
    tl=tiledlayout(nGrids,2,'TileSpacing','compact','Padding','compact');
    title(tl,strrep(fileName,'_','\_'),'Interpreter','tex','FontWeight','bold');
    for g=1:nGrids
        ax1=nexttile(tl,(g-1)*2+1); hold(ax1,'on'); means=nan(1,3); has=false;
        for e=1:3
            vals=getEpochMetric(fileResult,epochNames{e},g,'MDR_Hz'); vals=vals(isfinite(vals));
            if isempty(vals), continue; end; has=true; j=deterministicJitter(numel(vals),0.13);
            scatter(ax1,e+j,vals,30,'o','filled','MarkerFaceAlpha',0.45,'MarkerEdgeAlpha',0.55,'DisplayName','Individual MU');
            means(e)=mean(vals,'omitnan'); plot(ax1,e,means(e),'kd','MarkerFaceColor','k','MarkerSize',9,'LineWidth',1.2,'DisplayName','Mean');
        end
        plot(ax1,1:3,means,'k-','LineWidth',1.5,'HandleVisibility','off'); xlim(ax1,[0.5 3.5]);
        xticks(ax1,1:3); xticklabels(ax1,epochLabels); ylabel(ax1,'MDR (Hz)'); title(ax1,sprintf('Grid %d - MDR',g)); grid(ax1,'on'); box(ax1,'off');
        if has, addUniqueLegend(ax1); end

        ax2=nexttile(tl,(g-1)*2+2); hold(ax2,'on'); means=nan(1,3); has=false;
        for e=1:3
            vals=100*getEpochMetric(fileResult,epochNames{e},g,'CoV_ISI'); vals=vals(isfinite(vals));
            if isempty(vals), continue; end; has=true; j=deterministicJitter(numel(vals),0.13);
            scatter(ax2,e+j,vals,30,'o','filled','MarkerFaceAlpha',0.45,'MarkerEdgeAlpha',0.55,'DisplayName','Individual MU');
            means(e)=mean(vals,'omitnan'); plot(ax2,e,means(e),'kd','MarkerFaceColor','k','MarkerSize',9,'LineWidth',1.2,'DisplayName','Mean');
        end
        plot(ax2,1:3,means,'k-','LineWidth',1.5,'HandleVisibility','off'); xlim(ax2,[0.5 3.5]);
        xticks(ax2,1:3); xticklabels(ax2,epochLabels); ylabel(ax2,'CoV ISI (%)'); title(ax2,sprintf('Grid %d - CoV ISI',g)); grid(ax2,'on'); box(ax2,'off');
        if has, addUniqueLegend(ax2); end
    end
    exportgraphics(fig,fullfile(outPath,[outBase '_' sanitizeFilename(fileName) '_MDR_CoVISI_Descriptive.png']),'Resolution',220);
    savefig(fig,fullfile(outPath,[outBase '_' sanitizeFilename(fileName) '_MDR_CoVISI_Descriptive.fig'])); close(fig);
end

function vals=getEpochMetric(fileResult,epochName,g,metricName)
    vals=[]; if ~isfield(fileResult,'Epochs')||~isfield(fileResult.Epochs,epochName), return; end
    ep=fileResult.Epochs.(epochName); fld=sprintf('Grid%d',g);
    if ~isfield(ep,fld)||~isfield(ep.(fld),metricName), return; end
    vals=ep.(fld).(metricName);
end

function j=deterministicJitter(n,width)
    if n<=1, j=0; else, j=linspace(-width,width,n); end
end

function addUniqueLegend(ax)
    ch=flipud(ax.Children); labels={}; handles=gobjects(0);
    for k=1:numel(ch)
        nm=ch(k).DisplayName;
        if isempty(nm)||strcmp(ch(k).HandleVisibility,'off'), continue; end
        if ~any(strcmp(labels,nm)), labels{end+1}=nm; handles(end+1)=ch(k); %#ok<AGROW>
        end
    end
    if ~isempty(handles), legend(ax,handles,labels,'Location','best','Box','off'); end
end

function s=sanitizeFilename(s)
    s=regexprep(s,'[^a-zA-Z0-9_-]','_');
end
