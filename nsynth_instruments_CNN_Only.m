function nsynth_instruments_CNN_Only
% Joe Blochberger, March 2022
% uses MATLAB R2020b
% note, you need two text files: meta_test.txt and meta_train_JAB_no_synth_lead.txt generated from database json files
clear all; close all; clc;
datasetFolder_train = fullfile('..\nsynth-train.jsonwav.tar\nsynth-train.jsonwav\nsynth-train');
datasetFolder_test = fullfile('..\nsynth-test.jsonwav.tar\nsynth-test.jsonwav\nsynth-test');
%cd('')
tic
%% set up training meta data from .txt file
metadata_train = readtable(fullfile(datasetFolder_train,'meta_train_JAB_no_synth_lead.txt'), ...
    'Delimiter',{'\t'}, ...
    'ReadVariableNames',false);
metadata_train.Properties.VariableNames = {'FileName','InstrumentFamily','SpecificInstrument'};
head(metadata_train)

%% set up testing metadata from .txt file
metadata_test = readtable(fullfile(datasetFolder_test,'meta_test.txt'), ...
    'Delimiter',{'\t'}, ...
    'ReadVariableNames',false);
metadata_test.Properties.VariableNames = {'FileName','InstrumentFamily','SpecificInstrument'};
head(metadata_test)

%% check if recordings are contaminating training and testing data
sharedRecordingLocations = intersect(metadata_test.SpecificInstrument,metadata_train.SpecificInstrument);
fprintf('Number of specific recording locations in both train and test sets = %d\n',numel(sharedRecordingLocations))

%% define filepaths for training and testing data
train_filePaths = fullfile(datasetFolder_train,'audio',metadata_train.FileName);
test_filePaths = fullfile(datasetFolder_test,'audio',metadata_test.FileName);

%% Create an audio datastore with wav and mp3 files from the samples folder
adsTrain = audioDatastore(train_filePaths, ...
    'Labels',categorical(metadata_train.InstrumentFamily), ...
    'IncludeSubfolders',true);
display(countEachLabel(adsTrain))

adsTest = audioDatastore(test_filePaths, ...
    'Labels',categorical(metadata_test.InstrumentFamily), ...
    'IncludeSubfolders',true);
display(countEachLabel(adsTest))

%% Reduce dataset if needed for testing
% reduceDataset = false;
reduceDataset = true;
if reduceDataset
    adsTrain = splitEachLabel(adsTrain,20);
    adsTest = splitEachLabel(adsTest,10);
end

%% read in audioDatastore information to see if it works
[data,adsInfo] = read(adsTrain);
data = data./max(data,[],'all');

fs = adsInfo.SampleRate;
sound(data,fs)

fprintf('Instrument = %s\n',adsTrain.Labels(1))

%% Reset audioDatastore once you're good
reset(adsTrain)

%% Feature extraction for CNN
dataMidSide(:,1) = data; % 
dataMidSide(:,2) = data; % the NSynth dataset is monophonic: https://magenta.tensorflow.org/datasets/nsynth 

%% Buffer the data for feature extraction
segmentLength = 1; % Four-second .wav file clips divided into one-second segments
segmentOverlap = 0.5; % arbitrary overlap

[dataBufferedMid,~] = buffer(dataMidSide(:,1),round(segmentLength*fs),round(segmentOverlap*fs),'nodelay');
[dataBufferedSide,~] = buffer(dataMidSide(:,2),round(segmentLength*fs),round(segmentOverlap*fs),'nodelay');
dataBuffered = zeros(size(dataBufferedMid,1),size(dataBufferedMid,2)+size(dataBufferedSide,2));
dataBuffered(:,1:2:end) = dataBufferedMid;
dataBuffered(:,2:2:end) = dataBufferedSide;

%% FFT information
windowLength = 2048;
samplesPerHop = 1024;
samplesOverlap = windowLength - samplesPerHop;
fftLength = 2*windowLength;
numBands = 128;

%% Spectrograms with mel scale on y-axis
spec = melSpectrogram(dataBuffered,fs, ...
    'Window',hamming(windowLength,'periodic'), ...
    'OverlapLength',samplesOverlap, ...
    'FFTLength',fftLength, ...
    'NumBands',numBands);

%% Do not want any -Inf to show up
spec = log10(spec+eps);

%% Reshape spectragram output for feature extraction
X = reshape(spec,size(spec,1),size(spec,2),size(data,2),[]);

%% Plot some figures of the melSpectrograms: 6 segments

for channel = 1:2:11
    figure
    melSpectrogram(dataBuffered(:,channel),fs, ...
        'Window',hamming(windowLength,'periodic'), ...
        'OverlapLength',samplesOverlap, ...
        'FFTLength',fftLength, ...
        'NumBands',numBands);
    title(sprintf('Segment %d',ceil(channel/2)))
    colormap turbo
end

%% Use parallel processing for training
pp = parpool('IdleTimeout',inf);

train_set_tall = tall(adsTrain);
xTrain = cellfun(@(x)HelperSegmentedMelSpectrograms_JABmono(x,fs, ...
    'SegmentLength',segmentLength, ...
    'SegmentOverlap',segmentOverlap, ...
    'WindowLength',windowLength, ...
    'HopLength',samplesPerHop, ...
    'NumBands',numBands, ...
    'FFTLength',fftLength), ...
    train_set_tall, ...
    'UniformOutput',false);
xTrain = gather(xTrain); % Error - 3/17/2022 @ 9:45 AM fixed
xTrain = cat(4,xTrain{:}); % 4D

test_set_tall = tall(adsTest);
xTest = cellfun(@(x)HelperSegmentedMelSpectrograms_JABmono(x,fs, ...
    'SegmentLength',segmentLength, ...
    'SegmentOverlap',segmentOverlap, ...
    'WindowLength',windowLength, ...
    'HopLength',samplesPerHop, ...
    'NumBands',numBands, ...
    'FFTLength',fftLength), ...
    test_set_tall, ...
    'UniformOutput',false);
xTest = gather(xTest);
xTest = cat(4,xTest{:});

%% Replicate the labels of the training and test sets so that they are in one-to-one correspondence with the segments.

numSegmentsPer10seconds = size(dataBuffered,2)/2;
yTrain = repmat(adsTrain.Labels,1,numSegmentsPer10seconds)';
yTrain = yTrain(:);

%% Data Augmentation for CNN

xTrainExtra = xTrain;
yTrainExtra = yTrain;
lambda = 0.5;
for i = 1:size(xTrain,4)

    % Find all available spectrograms with different labels.
    availableSpectrograms = find(yTrain~=yTrain(i));

    % Randomly choose one of the available spectrograms with a different label.
    numAvailableSpectrograms = numel(availableSpectrograms);
    idx = randi([1,numAvailableSpectrograms]);

    % Mix.
    xTrainExtra(:,:,:,i) = lambda*xTrain(:,:,:,i) + (1-lambda)*xTrain(:,:,:,availableSpectrograms(idx));

    % Specify the label as randomly set by lambda.
    if rand > lambda
        yTrainExtra(i) = yTrain(availableSpectrograms(idx));
    end
end
xTrain = cat(4,xTrain,xTrainExtra);
yTrain = [yTrain;yTrainExtra];

%% Summary
size(xTrain)
size(yTrain)
summary(yTrain)

%% Define and Train CNN

imgSize = [size(xTrain,1),size(xTrain,2),size(xTrain,3)];
numF = 32;
layers = [ ...
    imageInputLayer(imgSize)

    batchNormalizationLayer

    convolution2dLayer(3,numF,'Padding','same')
    batchNormalizationLayer
    reluLayer
    convolution2dLayer(3,numF,'Padding','same')
    batchNormalizationLayer
    reluLayer

    maxPooling2dLayer(3,'Stride',2,'Padding','same')

    convolution2dLayer(3,2*numF,'Padding','same')
    batchNormalizationLayer
    reluLayer
    convolution2dLayer(3,2*numF,'Padding','same')
    batchNormalizationLayer
    reluLayer

    maxPooling2dLayer(3,'Stride',2,'Padding','same')

    convolution2dLayer(3,4*numF,'Padding','same')
    batchNormalizationLayer
    reluLayer
    convolution2dLayer(3,4*numF,'Padding','same')
    batchNormalizationLayer
    reluLayer

    maxPooling2dLayer(3,'Stride',2,'Padding','same')

    convolution2dLayer(3,8*numF,'Padding','same')
    batchNormalizationLayer
    reluLayer
    convolution2dLayer(3,8*numF,'Padding','same')
    batchNormalizationLayer
    reluLayer

    globalAveragePooling2dLayer

    dropoutLayer(0.5)

    fullyConnectedLayer(size(countEachLabel(adsTest),1)) % make sure output size equals ads table Label size
    softmaxLayer
    classificationLayer];

%% Training Options

miniBatchSize = 128;
tuneme = 128;
lr = 0.05*miniBatchSize/tuneme;
options = trainingOptions('sgdm', ...
    'InitialLearnRate',lr, ...
    'MiniBatchSize',miniBatchSize, ...
    'Momentum',0.9, ...
    'L2Regularization',0.005, ...
    'MaxEpochs',8, ...
    'Shuffle','every-epoch', ...
    'Plots','training-progress', ...
    'Verbose',false, ...
    'LearnRateSchedule','piecewise', ...
    'LearnRateDropPeriod',2, ...
    'LearnRateDropFactor',0.2);

%% Train the Network
trainedNet = trainNetwork(xTrain,yTrain,layers,options);

%% Evaluate CNN
cnnResponsesPerSegment = predict(trainedNet,xTest);

%% Average the responses over each 10-second audio clip.

classes = trainedNet.Layers(end).Classes;
numFiles = numel(adsTest.Files);

counter = 1;
cnnResponses = zeros(numFiles,numel(classes));
for channel = 1:numFiles
    cnnResponses(channel,:) = sum(cnnResponsesPerSegment(counter:counter+numSegmentsPer10seconds-1,:),1)/numSegmentsPer10seconds;
    counter = counter + numSegmentsPer10seconds;
end

%% For each 10-second audio clip, choose the maximum of the predictions, then map it to the corresponding predicted location.

[~,classIdx] = max(cnnResponses,[],2);
cnnPredictedLabels = classes(classIdx);

%% Call confusionchart (Deep Learning Toolbox) to visualize the accuracy on the test set.

figure('Units','normalized','Position',[0.2 0.2 0.5 0.5])
cm = confusionchart(adsTest.Labels,cnnPredictedLabels,'title','Test Accuracy - CNN');
cm.ColumnSummary = 'column-normalized';
cm.RowSummary = 'row-normalized';

fprintf('Average accuracy of CNN = %0.2f\n',mean(adsTest.Labels==cnnPredictedLabels)*100)

%% shut off parallel processing pool
delete(pp)
toc
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%HelperSegmentedMelSpectrograms
function X = HelperSegmentedMelSpectrograms_JABmono(x,fs,varargin)

p = inputParser;
addParameter(p,'WindowLength',1024);
addParameter(p,'HopLength',512);
addParameter(p,'NumBands',128);
addParameter(p,'SegmentLength',1);
addParameter(p,'SegmentOverlap',0);
addParameter(p,'FFTLength',1024);
parse(p,varargin{:})
params = p.Results;

% x = [sum(x,2),x(:,1)-x(:,2)]; % if stereo
x(:,1) = x; x(:,2) = x;% if mono
x = x./max(max(x));

[xb_m,~] = buffer(x(:,1),round(params.SegmentLength*fs),round(params.SegmentOverlap*fs),'nodelay');
[xb_s,~] = buffer(x(:,2),round(params.SegmentLength*fs),round(params.SegmentOverlap*fs),'nodelay');
xb = zeros(size(xb_m,1),size(xb_m,2)+size(xb_s,2));
xb(:,1:2:end) = xb_m;
xb(:,2:2:end) = xb_s;

spec = melSpectrogram(xb,fs, ...
    'Window',hamming(params.WindowLength,'periodic'), ...
    'OverlapLength',params.WindowLength - params.HopLength, ...
    'FFTLength',params.FFTLength, ...
    'NumBands',params.NumBands, ...
    'FrequencyRange',[0,floor(fs/2)]);
spec = log10(spec+eps);

X = reshape(spec,size(spec,1),size(spec,2),size(x,2),[]);
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%