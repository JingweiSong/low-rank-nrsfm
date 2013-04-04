close all;
rng('default');

K = 5;
scale_stddev = sqrt(2);
omega_stddev = 5 / 180 * pi;
use_akhter_data = input('Use data of Akhter? (true, false) ');

if use_akhter_data
  % Load mocap sequence.
  seq_name = input('Sequence? (drink, pickup, stretch, yoga) ', 's');
  mocap_file = ['../data/akhter-2008/', seq_name];
  load(mocap_file, 'S', 'Rs');
  F = size(Rs, 1) / 2;
  P = size(S, 2);

%  % [2F, 3] -> [2, F, 3] -> [2, 3, F]
%  rotations = permute(reshape(Rs, [2, F, 3]), [1, 3, 2]);
%  % Scale each frame.
%  scales = exp(log(scale_stddev) * randn(F, 1));
%  scaled_rotations = bsxfun(@times, rotations, reshape(scales, [1, 1, F]));
  clear Rs;

  structure = structure_from_matrix(S);
  clear S;
else
  % Load mocap sequence.
  data = load('../data/mocap-data.mat');
  num_sequences = size(data.sequences, 4);
  mocap_index = input(sprintf('Mocap index? (1, ..., %d) ', num_sequences));
  F = size(data.sequences, 1);
  P = size(data.sequences, 2);
  structure = data.sequences(:, :, :, mocap_index);
  % [F, P, 3] -> [3, P, F]
  structure = permute(structure, [3, 2, 1]);
end

% Angular change in each frame.
%omegas = omega_stddev * randn(F, 1);
omegas = omega_stddev * ones(F, 1);
% Angle in each frame.
thetas = cumsum(omegas) + rand() * 2 * pi;
% Scale in each frame.
scales = exp(log(scale_stddev) * randn(F, 1));

% Generate camera motion.
scene = generate_scene_for_sequence(structure, thetas, scales);

% Extract cameras.
scales = zeros(F, 1);
rotations = zeros(2, 3, F);
scaled_rotations = zeros(2, 3, F);
for t = 1:F
  scaled_rotations(:, :, t) = scene.cameras(t).P(1:2, 1:3);
  scales(t) = norm(scaled_rotations(:, :, t), 'fro') / sqrt(2);
  rotations(:, :, t) = 1 / scales(t) * scaled_rotations(:, :, t);
end

% Subtract centroid.
centroid = mean(structure, 2);
structure_unaligned = bsxfun(@minus, structure, centroid);

% Align shapes.
[structure_tilde, ref_frame] = congeal_shapes(structure_unaligned, 1e-6, 20);
% Apply inverse rotations to cameras.
world_cameras = rotations;
for t = 1:F
  R = ref_frame(:, :, t);
  rotations(:, :, t) = world_cameras(:, :, t) * R';
  scaled_rotations(:, :, t) = scaled_rotations(:, :, t) * R';
end

%% Project S on to low-rank manifold.
%S = structure_to_matrix(structure_tilde);
%S_sharp = k_reshape(S, 3);
%S_sharp = project_rank(S_sharp, K);
%S = k_unreshape(S_sharp, 3);
%% Restore centroid.
%structure_tilde = structure_from_matrix(S);
%structure = bsxfun(@plus, structure_tilde, centroid);

% Project.
R = block_diagonal_cameras(scaled_rotations);
S = structure_to_matrix(structure_tilde);
W_tilde = R * S;

projections_tilde = projections_from_matrix(W_tilde);

% Apply scale to (centered) structure instead of cameras.
scaled_structure = bsxfun(@times, structure_tilde, reshape(scales, [1, 1, F]));

R = block_diagonal_cameras(rotations);
S = structure_to_matrix(scaled_structure);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Modified solution for cameras of Dai 2012

rotations_trace = find_rotations_trace(projections, K, 1e6);
%rotations_trace = find_rotations_dai(M_hat);

% Rotate ground truth structure to match estimated cameras.
structure_rel = zeros(3, P, F);
for t = 1:F
  U = rotations_trace(:, :, t);
  U = [U; cross(U(1, :), U(2, :))];
  V = rotations(:, :, t);
  V = [V; cross(V(1, :), V(2, :))];
  % V S = U X = U (U' V S)
  structure_rel(:, :, t) = U' * V * scaled_structure(:, :, t);
end
S_rel = structure_to_matrix(structure_rel);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Xiao 2004

[structure_hat, rotations_hat] = nrsfm_basis_constraints(projections_tilde, K);

R_hat = block_diagonal_cameras(rotations_hat);
S_hat = structure_to_matrix(structure_hat);

fprintf('Reprojection error (Xiao 2004) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('3D error (Xiao 2004) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

%fprintf('Any key to continue\n');
%pause;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Dai 2012 solution for structure

fprintf('Constrained nuclear norm solution...\n');

rho = 1e-6;
max_iter = 200;
structure_hat = find_structure_constrained_nuclear_norm(projections_tilde, ...
    rotations_trace, [], 400, 1e-6, 1.1, 1e6);

R_hat = block_diagonal_cameras(rotations_trace);
structure_planar = structure_from_matrix(pinv(full(R_hat)) * W_tilde);

fprintf('nuclear_norm(ground_truth) = %g\n', ...
    nuclear_norm(k_reshape(structure_to_matrix(structure_rel), 3)));
fprintf('nuclear_norm(planar) = %g\n', ...
    nuclear_norm(k_reshape(structure_to_matrix(structure_planar), 3)));
fprintf('nuclear_norm(solution) = %g\n', ...
    nuclear_norm(k_reshape(structure_to_matrix(structure_hat), 3)));

fprintf('projection_error(ground_truth) = %g\n', ...
    norm(W_tilde - R_hat * S_rel, 'fro') / norm(W_tilde, 'fro'));

S_planar = structure_to_matrix(structure_planar);

fprintf('projection_error(planar) = %g\n', ...
    norm(W_tilde - R_hat * S_planar, 'fro') / norm(W_tilde, 'fro'));
fprintf('shape_error(planar) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_planar));

S_hat = structure_to_matrix(structure_hat);

fprintf('projection_error(solution) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('shape_error(solution) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

structure_nuclear = structure_hat;
[basis_nuclear, coeff_nuclear] = factorize_structure(structure_nuclear, K);

keyboard;
%fprintf('Any key to continue\n');
%pause;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Dai 2012 solution for structure, but with regularization not constraint.

fprintf('Regularized nuclear norm solution...\n');

lambda = 1e6;
structure_hat = find_structure_nuclear_norm_regularized(projections_tilde, ...
    rotations_trace, lambda, [], 400, 1e-6, 1.1, 1e6);

R_hat = block_diagonal_cameras(rotations_trace);
S_hat = structure_to_matrix(structure_hat);

fprintf('projection_error(solution) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('shape_error(solution) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

structure_nuclear_reg = structure_hat;

keyboard;
%fprintf('Any key to continue\n');
%pause;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Rank constraint by iterating Dai 2012 solution for structure

fprintf('Rank problem by sweeping lambda...\n');

[structure_hat, basis_hat, coeff_hat] = find_structure_nuclear_norm_sweep(...
    projections_tilde, rotations_trace, K, [], 200, 1e-6, 1.1, 1e6);

R_hat = block_diagonal_cameras(rotations_trace);
S_hat = structure_to_matrix(structure_hat);

fprintf('projection_error(solution) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('shape_error(solution) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

return;
%fprintf('Any key to continue\n');
%pause;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Nonlinear refinement.

for k = 1:5
  % Initialize with ground truth structure.
  R_hat = block_diagonal_cameras(rotations_trace);
  [basis, coeff] = factorize_structure(structure_rel, k);
  structure_low_rank = compose_structure(basis, coeff);
  S_low_rank = structure_to_matrix(structure_low_rank);

  [structure_hat, rotations_hat] = nrsfm_nonlinear(projections_tilde, ...
      rotations_trace, basis, coeff, 200, 1e-4);

  fprintf('k = %d\n', k);
  fprintf('projection_error(ground_truth) = %g\n', ...
      norm(W_tilde - R_hat * S_rel, 'fro') / norm(W_tilde, 'fro'));
  fprintf('projection_error(low_rank) = %g\n', ...
      norm(W_tilde - R_hat * S_low_rank, 'fro') / norm(W_tilde, 'fro'));

  R_hat = block_diagonal_cameras(rotations_hat);
  S_hat = structure_to_matrix(structure_hat);
  fprintf('projection_error(non-linear) = %g\n', ...
      norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
  fprintf('shape_error(non-linear) = %g\n', ...
      min_total_shape_error(structure_tilde, structure_hat));

  keyboard;
  %fprintf('Any key to continue\n');
  %pause;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Nonlinear refinement.

[structure_hat, rotations_hat] = nrsfm_nonlinear(projections_tilde, ...
    rotations, basis_hat, coeff_hat, 1000, 1e-4);

R_hat = block_diagonal_cameras(rotations_hat);
S_hat = structure_to_matrix(structure_hat);

fprintf('Reprojection error (non-linear) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('3D error (non-linear) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

%fprintf('Any key to continue\n');
%pause;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Our solution for structure using the nullspace

fprintf('Linear solution...\n');

structure_hat = find_structure_nullspace(projections_tilde, rotations_trace, K);

R_hat = block_diagonal_cameras(rotations_trace);
% [3, P, F] -> [3, F, P] -> [3F, P]
S_hat = structure_hat;
S_hat = permute(S_hat, [1, 3, 2]);
S_hat = reshape(S_hat, [3 * F, P]);

fprintf('Reprojection error (linear) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('3D error (linear) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

%fprintf('Any key to continue\n');
%pause;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Solve for both structure and motion given estimate of R.
%
%[Rs_nrsfm_nuclear, structure_nrsfm_nuclear] = nrsfm_constrained_nuclear_norm(...
%    projections_tilde, rotations_trace, 1, 1, 200, 10, 10, 10);
%
%R_mat = block_diagonal_cameras(Rs_nrsfm_nuclear);
%% [3, P, F] -> [3, F, P] -> [3F, P]
%S_mat = structure_nrsfm_nuclear;
%S_mat = permute(S_mat, [1, 3, 2]);
%S_mat = reshape(S_mat, [3 * F, P]);
%
%fprintf('Reprojection error (NRSFM nuclear) = %g\n', ...
%    norm(W_tilde - R_mat * S_mat, 'fro') / norm(W_tilde, 'fro'));
%fprintf('3D error (NRSFM nuclear) = %g\n', ...
%    min_total_shape_error(structure_tilde, structure_nrsfm_nuclear));
%
%%fprintf('Any key to continue\n');
%%pause;
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Nonlinear refinement of constrained nuclear norm ADMM solution for S and R.
%
%[Rs_refined_nrsfm_nuclear, structure_refined_nrsfm_nuclear] = ...
%    nrsfm_nonlinear(projections_tilde, Rs_nrsfm_nuclear, ...
%      structure_nrsfm_nuclear, K, 1000, 1e-4);
%
%R_mat = block_diagonal_cameras(Rs_refined_nrsfm_nuclear);
%% [3, P, F] -> [3, F, P] -> [3F, P]
%S_mat = structure_refined_nrsfm_nuclear;
%S_mat = permute(S_mat, [1, 3, 2]);
%S_mat = reshape(S_mat, [3 * F, P]);
%
%fprintf('Reprojection error (refined NRSFM nuclear) = %g\n', ...
%    norm(W_tilde - R_mat * S_mat, 'fro') / norm(W_tilde, 'fro'));
%fprintf('3D error (refined NRSFM nuclear) = %g\n', ...
%    min_total_shape_error(structure_tilde, structure_refined_nrsfm_nuclear));
%
%%fprintf('Any key to continue\n');
%%pause;
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Solve for both structure and motion given estimate of R.
%
%[Rs_nrsfm_rank, structure_nrsfm_rank] = nrsfm_fixed_rank(projections_tilde, ...
%    rotations_trace, K, 1, 1, 200, 10, 10, 10);
%
%R_mat = block_diagonal_cameras(Rs_nrsfm_rank);
%% [3, P, F] -> [3, F, P] -> [3F, P]
%S_mat = structure_nrsfm_rank;
%S_mat = permute(S_mat, [1, 3, 2]);
%S_mat = reshape(S_mat, [3 * F, P]);
%
%fprintf('Reprojection error (NRSFM rank) = %g\n', ...
%    norm(W_tilde - R_mat * S_mat, 'fro') / norm(W_tilde, 'fro'));
%fprintf('3D error (NRSFM rank) = %g\n', ...
%    min_total_shape_error(structure_tilde, structure_nrsfm_rank));
%
%%fprintf('Any key to continue\n');
%%pause;
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Nonlinear refinement of rank-constrained ADMM solution for S and R.
%
%[Rs_refined_nrsfm_rank, structure_refined_nrsfm_rank] = nrsfm_nonlinear(...
%    projections_tilde, Rs_nrsfm_rank, structure_nrsfm_rank, K, 1000, 1e-4);
%
%R_mat = block_diagonal_cameras(Rs_refined_nrsfm_rank);
%% [3, P, F] -> [3, F, P] -> [3F, P]
%S_mat = structure_refined_nrsfm_rank;
%S_mat = permute(S_mat, [1, 3, 2]);
%S_mat = reshape(S_mat, [3 * F, P]);
%
%fprintf('Reprojection error (refined NRSFM rank) = %g\n', ...
%    norm(W_tilde - R_mat * S_mat, 'fro') / norm(W_tilde, 'fro'));
%fprintf('3D error (refined NRSFM rank) = %g\n', ...
%    min_total_shape_error(structure_tilde, structure_refined_nrsfm_rank));
%
%%fprintf('Any key to continue\n');
%%pause;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Nullspace alternation, updating camera using motion matrix.
%
%clear rotations_hat structure_hat basis_hat coeff_hat R_hat S_hat;
%
%[structure_hat, rotations_hat] = nrsfm_nullspace_alternation_algebraic(...
%    projections_tilde, rotations_trace, K, 40);
%
%R_hat = block_diagonal_cameras(rotations_hat);
%% [3, P, F] -> [3, F, P] -> [3F, P]
%S_hat = structure_hat;
%S_hat = permute(S_hat, [1, 3, 2]);
%S_hat = reshape(S_hat, [3 * F, P]);
%
%fprintf('Reprojection error (algebraic nullspace alternation) = %g\n', ...
%    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
%fprintf('3D error (algebraic nullspace alternation) = %g\n', ...
%    min_total_shape_error(structure_tilde, structure_hat));
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Nullspace alternation, updating camera using structure.
%
%clear rotations_hat structure_hat basis_hat coeff_hat R_hat S_hat;
%
%[structure_hat, rotations_hat] = nrsfm_nullspace_alternation(...
%    projections_tilde, rotations_trace, K, 40);
%
%R_hat = block_diagonal_cameras(rotations_hat);
%% [3, P, F] -> [3, F, P] -> [3F, P]
%S_hat = structure_hat;
%S_hat = permute(S_hat, [1, 3, 2]);
%S_hat = reshape(S_hat, [3 * F, P]);
%
%fprintf('Reprojection error (nullspace alternation) = %g\n', ...
%    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
%fprintf('3D error (nullspace alternation) = %g\n', ...
%    min_total_shape_error(structure_tilde, structure_hat));
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Simple alternation, initialized using nullspace method.
%
%clear rotations_hat structure_hat basis_hat coeff_hat R_hat S_hat;
%
%[~, basis_hat] = find_structure_nullspace(projections_tilde, ...
%    rotations_trace, K);
%[structure_hat, rotations_hat] = nrsfm_alternation(projections_tilde, ...
%    rotations_trace, basis_hat, 80);
%
%R_hat = block_diagonal_cameras(rotations_hat);
%% [3, P, F] -> [3, F, P] -> [3F, P]
%S_hat = structure_hat;
%S_hat = permute(S_hat, [1, 3, 2]);
%S_hat = reshape(S_hat, [3 * F, P]);
%
%fprintf('Reprojection error (homogeneous alternation) = %g\n', ...
%    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
%fprintf('3D error (homogeneous alternation) = %g\n', ...
%    min_total_shape_error(structure_tilde, structure_hat));
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Minimize projection error regularized by nuclear norm.
%
%clear rotations_hat structure_hat basis_hat coeff_hat R_hat S_hat;
%
%lambda = 1;
%[structure_hat, rotations_hat] = nrsfm_nuclear_norm_regularizer(...
%    projections_tilde, structure_nuclear_reg, rotations_trace, lambda, 1, ...
%    200, 10, 10, 10);
%
%R_hat = block_diagonal_cameras(rotations_hat);
%% [3, P, F] -> [3, F, P] -> [3F, P]
%S_hat = structure_hat;
%S_hat = permute(S_hat, [1, 3, 2]);
%S_hat = reshape(S_hat, [3 * F, P]);
%
%fprintf('Reprojection error (nuclear norm regularizer) = %g\n', ...
%    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
%fprintf('3D error (nuclear norm regularizer) = %g\n', ...
%    min_total_shape_error(structure_tilde, structure_hat));

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% BALM

clear rotations_hat structure_hat basis_hat coeff_hat R_hat S_hat;

[structure_hat, rotations_hat] = nrsfm_balm_approximate(projections_tilde, ...
    rotations_trace, coeff_nuclear, 1, 80, 10, 10, 10);

R_hat = block_diagonal_cameras(rotations_hat);
% [3, P, F] -> [3, F, P] -> [3F, P]
S_hat = structure_hat;
S_hat = permute(S_hat, [1, 3, 2]);
S_hat = reshape(S_hat, [3 * F, P]);

fprintf('Reprojection error (BALM) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('3D error (BALM) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Alternation with metric projections

clear rotations_hat structure_hat basis_hat coeff_hat R_hat S_hat;

[structure_hat, rotations_hat] = nrsfm_metric_projections(projections_tilde, ...
    rotations_trace, coeff_nuclear, 40);

R_hat = block_diagonal_cameras(rotations_hat);
% [3, P, F] -> [3, F, P] -> [3F, P]
S_hat = structure_hat;
S_hat = permute(S_hat, [1, 3, 2]);
S_hat = reshape(S_hat, [3 * F, P]);

fprintf('Reprojection error (Alternation with metric projections) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('3D error (Alternation with metric projections) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% BALM with metric projections

clear rotations_hat structure_hat basis_hat coeff_hat R_hat S_hat;

[structure_hat, rotations_hat] = nrsfm_balm_metric_projections(...
    projections_tilde, rotations_trace, coeff_nuclear, 1, 40, 10, 10, 10);

R_hat = block_diagonal_cameras(rotations_hat);
% [3, P, F] -> [3, F, P] -> [3F, P]
S_hat = structure_hat;
S_hat = permute(S_hat, [1, 3, 2]);
S_hat = reshape(S_hat, [3 * F, P]);

fprintf('Reprojection error (BALM with metric projections) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('3D error (BALM with metric projections) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Alternation using homogeneous problem

clear rotations_hat structure_hat basis_hat coeff_hat R_hat S_hat;

[structure_hat, rotations_hat] = nrsfm_homogeneous_alternation(...
    projections_tilde, rotations_trace, basis_nuclear, 40);

R_hat = block_diagonal_cameras(rotations_hat);
% [3, P, F] -> [3, F, P] -> [3F, P]
S_hat = structure_hat;
S_hat = permute(S_hat, [1, 3, 2]);
S_hat = reshape(S_hat, [3 * F, P]);

fprintf('Reprojection error (homogeneous alternation) = %g\n', ...
    norm(W_tilde - R_hat * S_hat, 'fro') / norm(W_tilde, 'fro'));
fprintf('3D error (homogeneous alternation) = %g\n', ...
    min_total_shape_error(structure_tilde, structure_hat));
