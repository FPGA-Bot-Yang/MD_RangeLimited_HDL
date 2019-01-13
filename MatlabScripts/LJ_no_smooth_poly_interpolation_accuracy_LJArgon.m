%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Function: LJ_no_smooth_poly_interpolation_accuracy
% Evaluate the accuracy for interpolation
% Currently only evaluate the LJ force, equation refer to 'Efficient Calculation of Pairwise Nonbonded Forces', M. Chiu, A. Khan, M. Herbordt, FCCM2011
% The evaluation of the force and potential is also based on the LJ-Argon benchmark (https://github.com/KenNewcomb/LJ-Argon/blob/master/classes/simulation.py)
% Dependency: LJ_poly_interpolation_function.m (Generating the interpolation index and stored in txt file)
% Final result:
%       Fvdw_real: real result in single precision
%       Fvdw_poly: result evaluated using polynomial
%       average_error_rate: the average error rate for all the evaluated input r2
%
% Units of the input:
%       The ideal unit for position should be meter. 
%       For the LJArgon dataset, the real evaluated force is in range of (4.7371e-5,6.6029e+54), which exceed the range that can be coverd by single floating point
%
% By: Chen Yang
% 07/18/2018
% Boston University, CAAD Lab
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
clear all;

% output_scale_index: the output value can be out the scope of single-precision floating point, thus use this value to scale the output result back
% eps: eps of the particles, Unit J
% sigma: sigma value of the particles, Unit meter
% interpolation_order: interpolation order
% segment_num: # of large sections we have
% bin_num: # of bins per segment
% precision: # of datapoints for each interpolation
% min, max : range of distance

% Input & Output Scale Parameters
INPUT_SCALE_INDEX = 10^11;%50;                              % the readin position data is in the unit of meter, but it turns out that the minimum r2 value can be too small, lead to the overflow when calculating the r^-14, thus scale to A
OUTPUT_SCALE_INDEX = 10^-5;%10^100;                                % The scale value for the results of r14 & r8 term

% Dataset Paraemeters
DATASET_NAME = 'LJArgon';
% Ar
kb = 1.380e-23;         % Boltzmann constant (J/K)
eps = 1;%kb * 120;         % Unit J
sigma = 1;%3.4e-10;        % Unit meter

cutoff = single(7.65e-10 * INPUT_SCALE_INDEX);             % Cut-off radius
cutoff2 = cutoff * cutoff;
switchon = single(0.1);

interpolation_order = 1;                % interpolation order, no larger than 3
segment_num = 29;                       % # of segment
bin_num = 128;                          % # of bins per segment
precision = 8;                          % # of datepoints when generating the polynomial index 
% LJArgon min r2 is 2.272326e-7, after 100x scale the min r2 is 2.272326e-3
% LJArgon raw r2 range is 2.272326e-27 ~ 3.401961e-17 (unit meter)
raw_r2_min = 2.272326e-27;
scaled_r2_min = raw_r2_min * INPUT_SCALE_INDEX^2;
min_log_index = floor(log(scaled_r2_min)/log(2));
% Choose a min_range of 2^-15
min_range = 2^min_log_index;    % minimal range for the evaluation
% Based on cutoff and min_range to determine the # of segments
% Max range of cutoff is 
max_range = min_range * 2^segment_num;  % maximum range for the evaluation (currently this is the cutoff radius)

verification_datapoints = 10000;
verification_step_width = (max_range-min_range)/verification_datapoints;
r2 = single(min_range:verification_step_width:cutoff2-verification_step_width);
%r2 = [min_range cutoff cutoff2];
% initialize variables (in double precision)
inv_r2 = zeros(length(r2),1);
inv_r4 = zeros(length(r2),1);
inv_r6 = zeros(length(r2),1);
inv_r12 = zeros(length(r2),1);
inv_r8 = zeros(length(r2),1);
inv_r14 = zeros(length(r2),1);
% The golden result for LJ term
vdw14_real = zeros(length(r2),1);
vdw8_real = zeros(length(r2),1);
vdw6_real = zeros(length(r2),1);
vdw12_real = zeros(length(r2),1);

s = zeros(length(r2),1);
ds = zeros(length(r2),1);
Fvdw_real = zeros(length(r2),1);
Fvdw_poly = zeros(size(r2,2),1);

% Coefficient gen (random number), independent of r
% Not used here
Aij = 8;
Bij = 6;

%% Evaluate the real result in single precision (in double precision)
for i = 1:size(r2,2)
    % calculate the real value
    inv_r2(i) = 1 / r2(i);
    inv_r4(i) = inv_r2(i) * inv_r2(i);

    inv_r6(i)  = inv_r2(i) * inv_r4(i);
    inv_r12(i) = inv_r6(i) * inv_r6(i);

    inv_r14(i) = inv_r12(i) * inv_r2(i);
    inv_r8(i)  = inv_r6(i)  * inv_r2(i);
    
    vdw14_real(i) = OUTPUT_SCALE_INDEX * 48 * eps * sigma ^ 12 * inv_r14(i);
    vdw8_real(i)  = OUTPUT_SCALE_INDEX * 24 * eps * sigma ^ 6  * inv_r8(i);
   
    vdw6_real(i)  = OUTPUT_SCALE_INDEX * 4 * eps * sigma ^ 6  * inv_r6(i);
    vdw12_real(i) = OUTPUT_SCALE_INDEX * 4 * eps * sigma ^ 12  * inv_r12(i);
    
    % calculate the VDW force
    Fvdw_real(i) = vdw14_real(i) - vdw8_real(i);
end

%% Generate the interpolation table (only need to run this once if the interpolation parameter remains)
LJ_no_smooth_poly_interpolation_function(interpolation_order,segment_num, bin_num,precision,min_range,max_range,cutoff,switchon,OUTPUT_SCALE_INDEX,eps,sigma);

%% Evaluate the interpolation result
% Load in the index data
fileID_0  = fopen('c0_14.txt', 'r');
fileID_1  = fopen('c1_14.txt', 'r');
if interpolation_order > 1
    fileID_2  = fopen('c2_14.txt', 'r');
end
if interpolation_order > 2
    fileID_3  = fopen('c3_14.txt', 'r');
end

fileID_4  = fopen('c0_8.txt', 'r');
fileID_5  = fopen('c1_8.txt', 'r');
if interpolation_order > 1
    fileID_6  = fopen('c2_8.txt', 'r');
end
if interpolation_order > 2
    fileID_7  = fopen('c3_8.txt', 'r');
end

% Fetch the index for the polynomials
read_in_c0_vdw14 = textscan(fileID_0, '%f');
read_in_c1_vdw14 = textscan(fileID_1, '%f');
if interpolation_order > 1
    read_in_c2_vdw14 = textscan(fileID_2, '%f');
end
if interpolation_order > 2
    read_in_c3_vdw14 = textscan(fileID_3, '%f');
end
read_in_c0_vdw8 = textscan(fileID_4, '%f');
read_in_c1_vdw8 = textscan(fileID_5, '%f');
if interpolation_order > 1
    read_in_c2_vdw8 = textscan(fileID_6, '%f');
end
if interpolation_order > 2
    read_in_c3_vdw8 = textscan(fileID_7, '%f');
end

% close file
fclose(fileID_0);
fclose(fileID_1);
if interpolation_order > 1
    fclose(fileID_2);
end
if interpolation_order > 2
    fclose(fileID_3);
end
fclose(fileID_4);
fclose(fileID_5);
if interpolation_order > 1
    fclose(fileID_6);
end
if interpolation_order > 2
    fclose(fileID_7);
end

% Start evaluation
for i = 1:size(r2,2)
    % Locate the segment of the current r2
    seg_ptr = 0;        % The first segment will be #0, second will be #1, etc....
    while(r2(i) >= min_range * 2^(seg_ptr+1))
        seg_ptr = seg_ptr + 1;
    end
    if(seg_ptr >= segment_num)      % if the segment pointer is larger than the maximum number of segment, then error out
        disp('Error occur: could not locate the segment for the input r2');
        exit;
    end
    
    % Locate the bin in the current segment
    segment_min = single(min_range * 2^seg_ptr);
    segment_max = segment_min * 2;
    segment_step = (segment_max - segment_min) / bin_num;
    bin_ptr = floor((r2(i) - segment_min)/segment_step) + 1;            % the bin_ptr will give which bin it locate
    
    % Calculate the index for table lookup
    lut_index = seg_ptr * bin_num + bin_ptr;
    
    % Fetch the index for the polynomials
    c0_vdw14 = single(read_in_c0_vdw14{1}(lut_index));
    c1_vdw14 = single(read_in_c1_vdw14{1}(lut_index));
    if interpolation_order > 1
        c2_vdw14 = single(read_in_c2_vdw14{1}(lut_index));
    end
    if interpolation_order > 2
        c3_vdw14 = single(read_in_c3_vdw14{1}(lut_index));
    end
    c0_vdw8 = single(read_in_c0_vdw8{1}(lut_index));
    c1_vdw8 = single(read_in_c1_vdw8{1}(lut_index));
    if interpolation_order > 1
        c2_vdw8 = single(read_in_c2_vdw8{1}(lut_index));
    end
    if interpolation_order > 2
        c3_vdw8 = single(read_in_c3_vdw8{1}(lut_index));
    end
    
    % Calculate the poly value
    switch(interpolation_order)
        case 1
            vdw14 = polyval([c1_vdw14 c0_vdw14], r2(i));
            vdw8 = polyval([c1_vdw8 c0_vdw8], r2(i));
        case 2
            vdw14 = polyval([c2_vdw14 c1_vdw14 c0_vdw14], r2(i));
            vdw8 = polyval([c2_vdw8 c1_vdw8 c0_vdw8], r2(i));
        case 3
            vdw14 = polyval([c3_vdw14 c2_vdw14 c1_vdw14 c0_vdw14], r2(i));
            vdw8 = polyval([c3_vdw8 c2_vdw8 c1_vdw8 c0_vdw8], r2(i));
    end
    % Calculate the force
    Fvdw_poly(i) = vdw14 - vdw8;
end


%% Evaluate the Error rate
diff_rate = zeros(size(r2,2),1);
for i = 1:size(r2,2)
    difference = Fvdw_poly(i) - Fvdw_real(i);
    diff_rate(i) = abs(difference / Fvdw_real(i));
end

average_error_rate = sum(diff_rate) / size(r2,2);
fprintf('The average error rate is %f\n', average_error_rate);

%% Profiling
profiling_output_file_name = strcat(DATASET_NAME,'_PreEvaluation_Profiling_Data.txt');
fileID = fopen(profiling_output_file_name, 'wt');
fprintf(fileID, 'Dataset: %s\n', DATASET_NAME);
fprintf(fileID, '\tr2 range is: (%e, %e)\n', min(r2), max(r2));
fprintf(fileID, '\tvdw14_real range is: (%e, %e)\n', min(abs(vdw14_real)), max(vdw14_real));
fprintf(fileID, '\tvdw8_real range is: (%e, %e)\n', min(abs(vdw8_real)), max(vdw8_real));
fprintf(fileID, '\tvdw12_real range is: (%e, %e)\n', min(abs(vdw12_real)), max(vdw12_real));
fprintf(fileID, '\tvdw6_real range is: (%e, %e)\n', min(abs(vdw6_real)), max(vdw6_real));
fprintf(fileID, '\tFvdw_real range is: (%e, %e)\n', min(abs(Fvdw_real)), max(Fvdw_real));
fprintf(fileID, '\tFvdw_poly range is: (%e, %e)\n', min(abs(Fvdw_poly)), max(Fvdw_poly));
fprintf(fileID, '\tAverage error rate is: %f%%\n', average_error_rate * 100);
fclose(fileID);