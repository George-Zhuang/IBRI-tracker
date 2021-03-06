function results = tracker(params)
%% Initialization
% Get sequence info
admm_gamma = params.admm_gamma;
admm_lambda = params.admm_lambda;
penalty = params.penaltyfa;
bucketing = params.bucket;
[seq, im] = get_sequence_info(params.seq);
params = rmfield(params, 'seq');
if isempty(im)
    seq.rect_position = [];
    [~, results] = get_sequence_results(seq);
    return;
end
% Init position
pos = seq.init_pos(:)';
% context position
target_sz = seq.init_sz(:)';
params.init_sz = target_sz;

% Feature settings
features = params.t_features;

% Set default parameters
params = init_default_params(params);

% Global feature parameters
if isfield(params, 't_global')
    global_fparams = params.t_global;
else
    global_fparams = [];
end

global_fparams.use_gpu = params.use_gpu;
global_fparams.gpu_id = params.gpu_id;

% Define data types
if params.use_gpu
    params.data_type = zeros(1, 'single', 'gpuArray');
else
    params.data_type = zeros(1, 'single');
end
params.data_type_complex = complex(params.data_type);

global_fparams.data_type = params.data_type;

init_target_sz = target_sz;

% Check if color image
if size(im,3) == 3
    if all(all(im(:,:,1) == im(:,:,2)))
        is_color_image = false;
    else
        is_color_image = true;
    end
else
    is_color_image = false;
end

if size(im,3) > 1 && is_color_image == false
    im = im(:,:,1);
end

% Check if mexResize is available and show warning otherwise.
params.use_mexResize = true;
global_fparams.use_mexResize = true;
try
    [~] = mexResize(ones(5,5,3,'uint8'), [3 3], 'auto');
catch err
    params.use_mexResize = false;
    global_fparams.use_mexResize = false;
end

% Calculate search area and initial scale factor
search_area = prod(init_target_sz * params.search_area_scale);
if search_area > params.max_image_sample_size
    currentScaleFactor = sqrt(search_area / params.max_image_sample_size);
elseif search_area < params.min_image_sample_size
    currentScaleFactor = sqrt(search_area / params.min_image_sample_size);
else
    currentScaleFactor = 1.0;
end
% target size at the initial scale
base_target_sz = target_sz / currentScaleFactor;

% window size, taking padding into account
switch params.search_area_shape
    case 'proportional'
        img_sample_sz = floor(base_target_sz * params.search_area_scale);     % proportional area, same aspect ratio as the target
    case 'square'
        img_sample_sz = repmat(sqrt(prod(base_target_sz * params.search_area_scale)), 1, 2); % square area, ignores the target aspect ratio
    case 'fix_padding'
        img_sample_sz = base_target_sz + sqrt(prod(base_target_sz * params.search_area_scale) + (base_target_sz(1) - base_target_sz(2))/4) - sum(base_target_sz)/2; % const padding
    case 'custom'
        img_sample_sz = [base_target_sz(1)*2 base_target_sz(2)*2];
end

[features, global_fparams, feature_info] = init_features(features, global_fparams, is_color_image, img_sample_sz, 'exact');

% Set feature info
img_support_sz = feature_info.img_support_sz;
feature_sz = unique(feature_info.data_sz, 'rows', 'stable');
feature_cell_sz = unique(feature_info.min_cell_size, 'rows', 'stable');
num_feature_blocks = size(feature_sz, 1);

small_filter_sz{1} = floor(base_target_sz/(feature_cell_sz(1,1)));

% Get feature specific parameters
feature_extract_info = get_feature_extract_info(features);

% Size of the extracted feature maps
feature_sz_cell = mat2cell(feature_sz, ones(1,num_feature_blocks), 2);
filter_sz = feature_sz;
filter_sz_cell = permute(mat2cell(filter_sz, ones(1,num_feature_blocks), 2), [2 3 1]);

filter_sz_cell_ours{1} = filter_sz_cell{1}; 

% initialize previous response map
for i = 1:params.F
    M_prev{i} = zeros(filter_sz_cell{1});
end

% The size of the label function DFT. Equal to the maximum filter size
[output_sz_hand, k1] = max(filter_sz, [], 1);

output_sz = output_sz_hand;

k1 = k1(1);
% Get the remaining block indices
block_inds = 1:num_feature_blocks;
block_inds(k1) = [];

% Construct the Gaussian label function
yf = cell(numel(num_feature_blocks), 1);
for i = 1:num_feature_blocks
    sz = filter_sz_cell{i};
    output_sigma = sqrt(prod(floor(base_target_sz/feature_cell_sz(i)))) * params.output_sigma_factor;
    rg           = circshift(-floor((sz(1)-1)/2):ceil((sz(1)-1)/2), [0 -floor((sz(1)-1)/2)]);
    cg           = circshift(-floor((sz(2)-1)/2):ceil((sz(2)-1)/2), [0 -floor((sz(2)-1)/2)]);
    [rs, cs]     = ndgrid(rg,cg);
    y            = exp(-0.5 * (((rs.^2 + cs.^2) / output_sigma^2)));
    yf          = fft2(y); 
end

temp = mod(sz,params.spatial);
middle = round(params.spatial/2);
divi = (sz - temp)/ params.spatial;
divicol(1:params.spatial) = divi(1);
divirol(1:params.spatial) = divi(2);
divicol(middle) = divicol(middle)+temp(1);
divirol(middle) = divirol(middle)+temp(2);
M_small = cell(params.spatial,params.spatial);
all_peak = true(50,50);
small_all_peak = M_small;
    
% Compute the cosine windows
cos_window = cellfun(@(sz) hann(sz(1))*hann(sz(2))', feature_sz_cell, 'uniformoutput', false);

% Pre-computes the grid that is used for socre optimization
ky = circshift(-floor((filter_sz_cell{1}(1) - 1)/2) : ceil((filter_sz_cell{1}(1) - 1)/2), [1, -floor((filter_sz_cell{1}(1) - 1)/2)]);
kx = circshift(-floor((filter_sz_cell{1}(2) - 1)/2) : ceil((filter_sz_cell{1}(2) - 1)/2), [1, -floor((filter_sz_cell{1}(2) - 1)/2)])';
newton_iterations = params.newton_iterations;

% Use the translation filter to estimate the scale
% lfl: parameters for scale estimation
scale_sigma = sqrt(params.num_scales) * params.scale_sigma_factor;
ss = (1:params.num_scales) - ceil(params.num_scales/2);
ys = exp(-0.5 * (ss.^2) / scale_sigma^2);
ysf = single(fft(ys));
if mod(params.num_scales,2) == 0
    scale_window = single(hann(params.num_scales+1));
    scale_window = scale_window(2:end);
else
    scale_window = single(hann(params.num_scales));
end
ss = 1:params.num_scales;
scaleFactors = params.scale_step.^(ceil(params.num_scales/2) - ss);
if params.scale_model_factor^2 * prod(params.init_sz) > params.scale_model_max_area
    params.scale_model_factor = sqrt(params.scale_model_max_area/prod(params.init_sz));
end

if prod(params.init_sz) > params.scale_model_max_area
    params.scale_model_factor = sqrt(params.scale_model_max_area/prod(params.init_sz));
end
scale_model_sz = floor(params.init_sz * params.scale_model_factor);

% set maximum and minimum scales
min_scale_factor = params.scale_step ^ ceil(log(max(5 ./ img_support_sz)) / log(params.scale_step));
max_scale_factor = params.scale_step ^ floor(log(min([size(im,1) size(im,2)] ./ base_target_sz)) / log(params.scale_step));

seq.time = 0;

% Define the learning variables
% h_current_key = cell(num_feature_blocks, 1);
cf_f = cell(num_feature_blocks, 1);

% Allocate
%scores_fs_feat = cell(1,1,num_feature_blocks);
scores_fs_feat = cell(1,1,3);

%ADMM predefine
T = prod(filter_sz_cell_ours{1});
xt{1} = single(zeros(filter_sz_cell_ours{1}(1),filter_sz_cell_ours{1}(2),42));
q_finit = single(zeros(filter_sz_cell_ours{1}(1),filter_sz_cell_ours{1}(2),42));
xtw = xt;
xtf = xt;
xl = xt;
xlw = xt;
xlf = xt;
learning_rate = params.learning_rate_1;
learning_rate2 = params.learning_rate_2;
%% Main loop here
while true
    % Read image
    if seq.frame > 0
        [seq, im] = get_sequence_frame(seq);
        if isempty(im)
            break;
        end
        if size(im,3) > 1 && is_color_image == false
            im = im(:,:,1);
        end
    else
        seq.frame = 1;
    end

    tic();
    
    if seq.frame > 15
        learning_rate = learning_rate2;
    end 
    
    % Target localization step
    
    % Do not estimate translation and scaling on the first frame, since we 
    % just want to initialize the tracker there
    if seq.frame > 1
        old_pos = inf(size(pos));
        iter = 1;
        
        %translation search
        while iter <= params.refinement_iterations && any(old_pos ~= pos)
            % Extract features at multiple resolutions
            sample_pos = round(pos);
%             sample_scale = currentScaleFactor*scaleFactors;
            xt = extract_features(im, sample_pos, currentScaleFactor, features, global_fparams, feature_extract_info);
            % Do windowing of features
            xtw = cellfun(@(feat_map, cos_window) bsxfun(@times, feat_map, cos_window), xt, cos_window, 'uniformoutput', false);
            % Compute the fourier series
            xtf = cellfun(@fft2, xtw, 'uniformoutput', false);
            
            % Compute convolution for each feature block in the Fourier domain
            % and the sum over all blocks.
            scores_fs_feat{k1} = gather(sum(bsxfun(@times, conj(cf_f{k1}), xtf{k1}), 3));
            scores_fs_sum = scores_fs_feat{k1};
            for k = block_inds
                scores_fs_feat{k} = gather(sum(bsxfun(@times, conj(cf_f{k}), xtf{k}), 3));
                scores_fs_feat{k} = resizeDFT2(scores_fs_feat{k}, output_sz);
                scores_fs_sum = scores_fs_sum +  scores_fs_feat{k};
            end
             
            % Also sum over all feature blocks.
            % Gives the fourier coefficients of the convolution response.
            scores_fs = permute(gather(scores_fs_sum), [1 2 4 3]);
            
            responsef_padded = resizeDFT2(scores_fs, output_sz);
            response = ifft2(responsef_padded, 'symmetric');
            [disp_row, disp_col, sind] = resp_newton(response, responsef_padded, newton_iterations, ky, kx, output_sz);

            % Compute the translation vector in pixel-coordinates and round
            % to the closest integer pixel.
            translation_vec = [disp_row, disp_col] .* (img_support_sz./output_sz) * currentScaleFactor;            
%             scale_change_factor = scaleFactors(sind);
            % update position
            old_pos = pos;
            pos = sample_pos + translation_vec;
%             if params.clamp_position
%                 pos = max([1 1], min([size(im,1) size(im,2)], pos));
%             end

            % SCALE SPACE SEARCH
            xs = get_scale_sample(im, pos, base_target_sz, currentScaleFactor * scaleFactors, scale_window, scale_model_sz);
            xsf = fft(xs,[],2);
            scale_response = real(ifft(sum(sf_num .* xsf, 1) ./ (sf_den + params.scale_lambda) ));            
            % find the maximum scale response
            recovered_scale = find(scale_response == max(scale_response(:)), 1);
            % update the scale
            currentScaleFactor = currentScaleFactor * scaleFactors(recovered_scale);
            if currentScaleFactor < min_scale_factor
                currentScaleFactor = min_scale_factor;
            elseif currentScaleFactor > max_scale_factor
                currentScaleFactor = max_scale_factor;
            end            

            M_curr = fftshift(response(:,:,sind));
            max_M_curr = max(M_curr(:));
%             figure(11)%Show response maps
%             surf(M_curr);
%             shading interp
%             colormap('jet')
%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%Disruptor-aware scheme%%%%%%%%%%%%%%%%%%%       
            if bucketing
                M_small = mat2cell(M_curr,divicol,divirol);
                all_peak = imregionalmax(M_curr);
                small_all_peak = mat2cell(all_peak,divicol,divirol);
                for i = 1:length(M_small(:))
                    if max(M_small{i}(:)) ~= max_M_curr
                        small_peak = max(M_small{i}(small_all_peak{i}==true));
                        if small_peak > params.thr * max_M_curr
                            M_small{i} = M_small{i} * (1/(penalty * (small_peak/max_M_curr)));
                        end
                    end
                end
                M_curr = cell2mat(M_small);
            end
%% %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%    
            [id_ymax_curr, id_xmax_curr] = find(M_curr == max_M_curr);
            % do shifting of previous response map 1
            for i = 1:params.F
                shift_y = id_ymax_curr - id_ymax_prev{i};
                shift_x = id_xmax_curr - id_xmax_prev{i};
                sz_shift_y = size(shift_y);
                sz_shift_x = size(shift_x);
                if(sz_shift_y(1) > 1)
                    shift_y = shift_y(1);
                end
                if(sz_shift_x(1) > 1)
                    shift_x = shift_x(1);
                end
                M_prev{i}= circshift(M_prev{i},shift_y,1);
                M_prev{i}= circshift(M_prev{i},shift_x,2); 
            end
       
            iter = iter + 1;
        end
    end
        
    

    %% Model update step
    % extract image region for training sample
    sample_pos = round(pos);
    xl = extract_features(im, sample_pos, currentScaleFactor, features, global_fparams, feature_extract_info);
    % do windowing of features
    xlw = cellfun(@(feat_map, cos_window) bsxfun(@times, feat_map, cos_window), xl, cos_window, 'uniformoutput', false);
    % compute the fourier series
    xlf = cellfun(@fft2, xlw, 'uniformoutput', false);
    % train the CF model for each feature
    for k = 1: 1
        
            if (seq.frame == 1)
            model_xf = xlf{k};
            else
            model_xf = ((1 - learning_rate) * model_xf) + (learning_rate * xlf{k});
            end
            
            q_f = q_finit;
            h_f = q_finit;
            l_f = q_finit;
            mu    = params.mu;
            betha = 10;
            mumax = 10000;
            i = 1;
            
            
            S_xx = sum(conj(model_xf) .* model_xf, 3);
            M_train = q_finit;
            for m = 1:params.F
                M_train = M_train + (admm_gamma(m)) * bsxfun(@times, M_prev{m}, model_xf);
            end
            M_train_Sxx = bsxfun(@times, M_train, S_xx);
            % ADMM solving process
            while (i <= params.admm_iterations)
                A = mu / (sum(admm_gamma) + 1);
                B = S_xx + A*T;
                S_lx = sum(conj(model_xf) .* l_f, 3);
                S_hx = sum(conj(model_xf) .* h_f, 3);
 
               %solve for Q
                q_f = (1 / mu) * ( ((1/T)*(bsxfun(@times, yf, model_xf)) + M_train - l_f + mu * h_f) - ...
                    bsxfun(@rdivide,((1/T)*(bsxfun(@times, model_xf, (S_xx .* yf))) + M_train_Sxx -  bsxfun(@times, model_xf, S_lx) + mu * (bsxfun(@times, model_xf, S_hx))), B));

                %   solve for G
                g = (T / (mu * T+  admm_lambda)) * ifft2((mu*q_f) + l_f);
                [sx,sy,g] = get_subwindow_no_window(g, floor(filter_sz_cell_ours{k}/2) , small_filter_sz{k});
                t = zeros(filter_sz_cell_ours{k}(1), filter_sz_cell_ours{k}(2), size(g,3));
                t(sx,sy,:) = g;
                h_f = fft2(t);

                %   update L
                l_f = l_f + (mu * (q_f - h_f));

                %   update mu- betha = 10.
                mu = min(betha * mu, mumax);
                i = i+1;
            end    
            cf_f{k} = q_f;  
    end
    if(seq.frame == 1)
            % Compute convolution for each feature block in the Fourier domain
            % and the sum over all blocks.
            scores_fs_feat{k1} = gather(sum(bsxfun(@times, conj(cf_f{k1}), xlf{k1}), 3));
            scores_fs_sum = scores_fs_feat{k1};
            for k = block_inds
                scores_fs_feat{k} = gather(sum(bsxfun(@times, conj(cf_f{k}), xlf{k}), 3));
                scores_fs_feat{k} = resizeDFT2(scores_fs_feat{k}, output_sz);
                scores_fs_sum = scores_fs_sum +  scores_fs_feat{k};
            end
             
            % Also sum over all feature blocks.
            % Gives the fourier coefficients of the convolution response.
            scores_fs = permute(gather(scores_fs_sum), [1 2 4 3]);
            
            responsef_padded = resizeDFT2(scores_fs, output_sz);
            response = ifft2(responsef_padded, 'symmetric');
            
            
            M_prev{1} = fftshift(response);
            max_M_prev{1} = max(M_prev{1}(:));
            [id_ymax_prev{1},id_xmax_prev{1}]= find(M_prev{1} == max_M_prev{1});
            for m = 2:params.F
%                 M_prev{m} = M_prev{m-1};
                id_ymax_prev{m} = id_ymax_prev{m-1};
                id_xmax_prev{m} = id_xmax_prev{m-1};
            end

    else
            for m = params.F : -1 :2
                M_prev{m} = M_prev{m-1};
                
                id_ymax_prev{m} = id_ymax_prev{m-1};
                id_xmax_prev{m} = id_xmax_prev{m-1};
            end
            M_prev{1} = M_curr;
            id_ymax_prev{1} = id_ymax_curr;
            id_xmax_prev{1} = id_xmax_curr;

    end
    
    %% Upadate Scale
    xs = get_scale_sample(im, pos, base_target_sz, currentScaleFactor * scaleFactors, scale_window, scale_model_sz);
    xsf = fft(xs,[],2);
    new_sf_num = bsxfun(@times, ysf, conj(xsf));
    new_sf_den = sum(xsf .* conj(xsf), 1);
    
    if seq.frame == 1
        sf_den = new_sf_den;
        sf_num = new_sf_num;
    else
        sf_den = (1 - params.learning_rate_scale) * sf_den + params.learning_rate_scale * new_sf_den;
        sf_num = (1 - params.learning_rate_scale) * sf_num + params.learning_rate_scale * new_sf_num;
    end
    % Update the target size (only used for computing output box)
    target_sz = base_target_sz * currentScaleFactor;
    
    
    %save position and calculate FPS
    tracking_result.center_pos = double(pos);
    tracking_result.target_size = double(target_sz);
    seq = report_tracking_result(seq, tracking_result);
    
    seq.time = seq.time + toc();
    
    %% Visualization
    if params.visualization
        rect_position_vis = [pos([2,1]) - (target_sz([2,1]) - 1)/2, target_sz([2,1])];
        im_to_show = double(im)/255;
        if size(im_to_show,3) == 1
            im_to_show = repmat(im_to_show, [1 1 3]);
        end
        figure(1)
        imagesc(im_to_show);
        hold on;
        rectangle('Position',rect_position_vis, 'EdgeColor','g', 'LineWidth',2);
        text(10, 10, [int2str(seq.frame) '/'  int2str(size(seq.image_files, 1))], 'color', [0 1 1]);
        hold off;
        axis off;axis image;set(gca, 'Units', 'normalized', 'Position', [0 0 1 1])
                    
        drawnow
    end
end

[~, results] = get_sequence_results(seq);

disp(['fps: ' num2str(results.fps)])

