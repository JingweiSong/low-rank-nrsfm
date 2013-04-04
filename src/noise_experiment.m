num_frames = 256;
num_sequences = 16;
downsample = 8;

omega_stddev = 5 * pi / 180;
scale_stddev = sqrt(2);
noise_stddevs = [0, 0.01, 0.1, 1, 10, 100];

num_noises = length(noise_stddevs);

% Load some mocap sequences.
if ~exist('../data/mocap-data.mat', 'file')
  sequences = random_mocap_sequences(num_frames, num_sequences, downsample, 42);
  save('../data/mocap-data', 'sequences');
else
  data = load('../data/mocap-data');
  sequences = data.sequences;
end

% In case these parameters differed in file which we loaded.
num_frames = size(sequences, 1);
num_points = size(sequences, 2);
num_sequences = min(num_sequences, size(sequences, 4));
sequences = sequences(:, :, :, 1:num_sequences);
% [F, P, 3, n] -> [3, P, F, n]
sequences = permute(sequences, [3, 2, 1, 4]);

K = 4;

% Project on to low rank.
for i = 1:num_sequences
  S = sequences(:, :, :, i);

  % Subtract 3D centroid from each frame.
  mu = mean(S, 2);
  S = bsxfun(@minus, S, mu);

  % Project on to rank-K manifold.
  S = structure_to_matrix(S);
  S = k_reshape(S, 3);
  S = project_rank(S, K);
  S = k_unreshape(S, 3);
  S = structure_from_matrix(S);

  % Restore centroid.
  S = bsxfun(@plus, S, mu);

  sequences(:, :, :, i) = S;
end

% Generate a camera for each sequence and project it.
scenes = generate_random_scene_for_all_sequences(sequences, omega_stddev, ...
    scale_stddev);

% Solvers which don't require initialization.
nrsfm_solvers = [...
  make_solver(@(projections) nrsfm_basis_constraints(projections, K), ...
    'Xiao (2004)', 'xiao'), ...
];

% Methods for initializing the cameras.
camera_solvers = [...
  make_solver(@(projections) find_rotations_rigid(projections), ...
    'Rigid cameras', 'rigid'), ...
  make_solver(@(projections) find_rotations_trace(projections, K, 1e6), ...
    'Trace norm cameras', 'trace'), ...
];

% Solvers which require initialization of cameras.
nrsfm_solvers_given_cameras = [...
  make_solver(...
    @(projections, rotations) nrsfm_nullspace_alternation(projections, ...
      rotations, K, 80), ...
    'Nullspace alternation', 'null'), ...
  make_solver(...
    @(projections, rotations) nrsfm_nullspace_alternation_algebraic(...
      projections, rotations, K, 80), ...
    'Nullspace alternation (algebraic)', 'null-alg'), ...
  make_solver(...
    @(projections, rotations) nrsfm_find_structure_adaptor(...
      @(projections, rotations) find_structure_constrained_nuclear_norm(...
        projections, rotations, 1e-6, 400, 1e-6, 1.1, 1e6), ...
      projections, rotations), ...
    'Structure only, nuclear norm (constrained)', ...
    'nuclear-equal'), ...
  arrayfun(@(lambda) make_solver(...
      @(projections, rotations) nrsfm_find_structure_adaptor(...
        @(projections, rotations) find_structure_nuclear_norm_regularized(...
          projections, rotations, lambda, 1, 400, 10, 10, 10), ...
        projections, rotations), ...
      sprintf('Structure only, nuclear norm (\\lambda = %g)', lambda), ...
      sprintf('nuclear-reg-%g', lambda)), ...
    [1e-2, 1, 1e2, 1e4]), ...
  make_solver(...
    @(projections, rotations) nrsfm_find_structure_adaptor(...
      @(projections, rotations) find_structure_nuclear_norm_sweep(...
        projections, rotations, K, 1, 200, 10, 10, 10), ...
      projections, rotations), ...
    'Structure only, sweep nuclear norm', 'nuclear-sweep'), ...
];

full_init_solvers = [...
  make_solver(...
    @(projections, rotations) nrsfm_init_find_structure_adaptor(...
      @(projections, rotations) find_structure_constrained_nuclear_norm(...
        projections, rotations, [], 400, 1e-6, 1.1, 1e6), ...
      projections, rotations, K), ...
    'Nuclear norm (constrained)', 'nuclear-equal'), ...
  make_solver(...
    @(projections, rotations) nrsfm_init_find_structure_adaptor(...
      @(projections, rotations) find_structure_nuclear_norm_sweep(...
        projections, rotations, K, [], 400, 1e-6, 1.1, 1e6), ...
      projections, rotations, K), ...
    'Nuclear norm (sweep)', 'nuclear-sweep'), ...
];

% Solvers which require initialization of cameras and coefficients.
nrsfm_solvers_full_init = [...
  make_solver(...
    @(projections, structure, rotations, basis, coeff) ...
      nrsfm_nonlinear(projections, rotations, basis, coeff, 200, 1e-4), ...
    'Non-linear', 'nonlinear'), ...
...  make_solver(...
...    @(projections, structure, rotations, basis, coeff) ...
...      nrsfm_balm_approximate(projections, rotations, coeff, 1, 200, 10, 10, ...
...        10), ...
...    'BALM', 'balm-approximate'), ...
...  make_solver(...
...    @(projections, structure, rotations, basis, coeff) ...
...      nrsfm_balm_metric_projections(projections, rotations, coeff, 1, 40, ...
...        10, 10, 10), ...
...    'BALM with metric projections', 'balm-metric'), ...
...  make_solver(...
...    @(projections, structure, rotations, basis, coeff) ...
...      nrsfm_metric_projections(projections, rotations, coeff, 40), ...
...    'Alternation with metric projections', 'alternation-metric'), ...
...  make_solver(...
...    @(projections, structure, rotations, basis, coeff) nrsfm_fixed_rank(...
...      projections, structure, rotations, K, 1, 1, 400, 10, 10, 10), ...
...    'Fixed rank', 'fixed-rank'), ...
...  make_solver(...
...    @(projections, structure, rotations, basis, coeff) ...
...      nrsfm_constrained_nuclear_norm(projections, structure, rotations, 1, ...
...        1, 400, 10, 10, 10), ...
...    'Nuclear norm (constrained)', 'nuclear-constrained'), ...
...  arrayfun(@(lambda) make_solver(...
...      @(projections, structure, rotations, basis, coeff) ...
...        nrsfm_nuclear_norm_regularizer(projections, structure, rotations, ...
...          lambda, 1, 400, 10, 10, 10), ...
...      sprintf('Nuclear norm (\\lambda = %g)', lambda), ...
...      sprintf('nuclear-regularized-%g', lambda)), ...
...    [1e-2, 1, 1e2, 1e4]), ...
];

%  make_solver(...
%    @(projections, rotations) nrsfm_homogeneous_alternation(projections, ...
%      rotations), ...
%    'Homogeneous alternation', 'homogeneous-alternation'), ...

solvers = struct(...
    'nrsfm_solvers', nrsfm_solvers, ...
    'camera_solvers', camera_solvers, ...
    'nrsfm_solvers_given_cameras', nrsfm_solvers_given_cameras, ...
    'full_init_solvers', full_init_solvers, ...
    'nrsfm_solvers_full_init', nrsfm_solvers_full_init);

% Allocate array.
clear noisy_scenes;
noisy_scenes(num_sequences, num_noises) = struct('projections', []);

% Add noise to projections.
for i = 1:num_sequences
  projections = scenes(i).projections;

  for j = 1:num_noises
    noise_stddev = noise_stddevs(j);

    noise = noise_stddev * randn(2, num_points, num_frames);
    noisy_scenes(i, j).projections = projections + noise;
  end
end

save('noise-experiment-setup', 'solvers', 'scenes', 'noisy_scenes', ...
    'noise_stddevs', 'omega_stddev', 'scale_stddev');

trial = @(scene) { noise_experiment_trial(solvers, scene) };

if exist('pararrayfun', 'file')
  config = struct('h_cpu', '4:00:00', 'virtual_free', '512M', ...
      'hostname', '!leffe*');
  solutions = pararrayfun(trial, noisy_scenes, num_sequences * num_noises, ...
      'v', config);
else
  warning('Could not find pararrayfun(), running in series.');
  solutions = arrayfun(trial, noisy_scenes(1));
end

% Repack.
num_solvers = numel(solutions{1});
solutions = reshape(cell2mat(solutions(:)), [size(solutions), num_solvers]);

save('noise-experiment-solutions', 'solutions');
