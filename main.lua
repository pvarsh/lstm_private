--
----  Copyright (c) 2014, Facebook, Inc.
----  All rights reserved.
----
----  This source code is licensed under the Apache 2 license found in the
----  LICENSE file in the root directory of this source tree. 
----


ok,cunn = pcall(require, 'fbcunn')
if not ok then
    ok,cunn = pcall(require,'cunn')
    if ok then
        print("warning: fbcunn not found. Falling back to cunn") 
        LookupTable = nn.LookupTable
    else
        print("Could not find cunn or fbcunn. Either is required")
        os.exit()
    end
else
    deviceParams = cutorch.getDeviceProperties(1)
    cudaComputeCapability = deviceParams.major + deviceParams.minor/10
    LookupTable = nn.LookupTable
end


require('nngraph')
require('base')
local stringx = require('pl.stringx')

ptb = require('data')

if not opt then
   print '==> processing options'
   cmd = torch.CmdLine()
   cmd:text()
   cmd:text()
   cmd:text('Options:')
   cmd:option('-load', false, 'Load model')
   cmd:option('-load_name', 'model.net', 'Model file name to load')
   cmd:option('-no_train', false, 'No train, play (Boolean)')
   cmd:option('-char', false, 'Character-level model (Boolean)')
   cmd:option('-seq_length', 20, 'Sequence length')
   cmd:option('-submission', false, 'Submission (Boolean)')
   cmd:text()
   opt = cmd:parse(arg or {})
end

-- Train 1 day and gives 82 perplexity.
--[[
local params = {batch_size=20,
                seq_length=35,
                layers=2,
                decay=1.15,
                rnn_size=1500,
                dropout=0.65,
                init_weight=0.04,
                lr=1,
                vocab_size=10000,
                max_epoch=14,
                max_max_epoch=55,
                max_grad_norm=10}
               ]]--

-- Trains 1h and gives test 115 perplexity.
local params = {batch_size=20,
                seq_length=20,
                layers=2,
                decay=2,
                rnn_size=200,
                dropout=0,
                init_weight=0.1,
                lr=1,
                vocab_size=10000,
                max_epoch=4,
                max_max_epoch=13,
                max_grad_norm=5,
                char_mult = 1
                }


params.seq_length = opt.seq_length

if opt.char then
  params.vocab_size = 50
  params.char_mult = 5.6
end

function transfer_data(x)
  return x:cuda()
end

--local state_train, state_valid, state_test
model = {}
--local paramx, paramdx

function lstm(i, prev_c, prev_h)
  local function new_input_sum()
    local i2h            = nn.Linear(params.rnn_size, params.rnn_size)
    local h2h            = nn.Linear(params.rnn_size, params.rnn_size)
    return nn.CAddTable()({i2h(i), h2h(prev_h)})
  end
  local in_gate          = nn.Sigmoid()(new_input_sum())
  local forget_gate      = nn.Sigmoid()(new_input_sum())
  local in_gate2         = nn.Tanh()(new_input_sum())
  local next_c           = nn.CAddTable()({
    nn.CMulTable()({forget_gate, prev_c}),
    nn.CMulTable()({in_gate,     in_gate2})
  })
  local out_gate         = nn.Sigmoid()(new_input_sum())
  local next_h           = nn.CMulTable()({out_gate, nn.Tanh()(next_c)})
  return next_c, next_h
end

function create_network()
  local x                = nn.Identity()()
  local y                = nn.Identity()()
  local prev_s           = nn.Identity()()
  local i                = {[0] = LookupTable(params.vocab_size,
                                                    params.rnn_size)(x)}
  local next_s           = {}
  local split         = {prev_s:split(2 * params.layers)}
  for layer_idx = 1, params.layers do
    local prev_c         = split[2 * layer_idx - 1]
    local prev_h         = split[2 * layer_idx]
    local dropped        = nn.Dropout(params.dropout)(i[layer_idx - 1])
    local next_c, next_h = lstm(dropped, prev_c, prev_h)
    table.insert(next_s, next_c)
    table.insert(next_s, next_h)
    i[layer_idx] = next_h
  end
  local h2y              = nn.Linear(params.rnn_size, params.vocab_size)
  local dropped          = nn.Dropout(params.dropout)(i[params.layers])
  local pred             = nn.LogSoftMax()(h2y(dropped))
  local err              = nn.ClassNLLCriterion()({pred, y})
  local module           = nn.gModule({x, y, prev_s},
                                      {err, nn.Identity()(next_s), pred})
  module:getParameters():uniform(-params.init_weight, params.init_weight)
  return transfer_data(module)
end

function setup()
  print("Creating a RNN LSTM network.")
  local core_network = create_network()
  paramx, paramdx = core_network:getParameters()
  model.s = {}
  model.ds = {}
  model.start_s = {}
  for j = 0, params.seq_length do
    model.s[j] = {}
    for d = 1, 2 * params.layers do
      model.s[j][d] = transfer_data(torch.zeros(params.batch_size, params.rnn_size))
    end
  end
  for d = 1, 2 * params.layers do
    model.start_s[d] = transfer_data(torch.zeros(params.batch_size, params.rnn_size))
    model.ds[d] = transfer_data(torch.zeros(params.batch_size, params.rnn_size))
  end
  model.core_network = core_network
  model.rnns = g_cloneManyTimes(core_network, params.seq_length)
  model.norm_dw = 0
  model.err = transfer_data(torch.zeros(params.seq_length))
end

function reset_state(state)
  state.pos = 1
  if model ~= nil and model.start_s ~= nil then
    for d = 1, 2 * params.layers do
      model.start_s[d]:zero()
    end
  end
end

function reset_ds()
  for d = 1, #model.ds do
    model.ds[d]:zero()
  end
end

function fp(state)
  g_replace_table(model.s[0], model.start_s)
  if state.pos + params.seq_length > state.data:size(1) then
    reset_state(state)
  end
  for i = 1, params.seq_length do
    local x = state.data[state.pos]
    local y = state.data[state.pos + 1]
    local s = model.s[i - 1]
    local pred
    model.err[i], model.s[i], pred = unpack(model.rnns[i]:forward({x, y, s}))
    state.pos = state.pos + 1
  end
  g_replace_table(model.start_s, model.s[params.seq_length])
  return model.err:mean()
end

function bp(state)
  paramdx:zero()
  reset_ds()
  for i = params.seq_length, 1, -1 do
    state.pos = state.pos - 1
    local x = state.data[state.pos]
    local y = state.data[state.pos + 1]
    local s = model.s[i - 1]
    local derr = transfer_data(torch.ones(1))
    local dpred = transfer_data(torch.zeros(params.batch_size, params.vocab_size))
    local tmp = model.rnns[i]:backward({x, y, s},
                                       {derr, model.ds, dpred})[3]
    g_replace_table(model.ds, tmp)
    cutorch.synchronize()
  end
  state.pos = state.pos + params.seq_length
  model.norm_dw = paramdx:norm()
  if model.norm_dw > params.max_grad_norm then
    local shrink_factor = params.max_grad_norm / model.norm_dw
    paramdx:mul(shrink_factor)
  end
  paramx:add(paramdx:mul(-params.lr))
end

function run_valid()
  reset_state(state_valid)
  g_disable_dropout(model.rnns)
  local len = (state_valid.data:size(1) - 1) / (params.seq_length)
  local perp = 0
  for i = 1, len do
    perp = perp + fp(state_valid)
  end
  print("Validation set perplexity : " .. g_f3(
                        torch.exp(params.char_mult * perp / len)
                        ))
  g_enable_dropout(model.rnns)
end

function run_test()
  reset_state(state_test)
  g_disable_dropout(model.rnns)
  local perp = 0
  local len = state_test.data:size(1)
  g_replace_table(model.s[0], model.start_s)
  for i = 1, (len - 1) do
    local x = state_test.data[i]
    local y = state_test.data[i + 1]
    local s = model.s[i - 1]
    perp_tmp, model.s[1] = unpack(model.rnns[1]:forward({x, y, model.s[0]}))
    perp = perp + perp_tmp[1]
    g_replace_table(model.s[0], model.s[1])
  end
  print("Test set perplexity : " .. g_f3(
                  torch.exp(params.char_mult * perp / (len - 1))
                  ))
  g_enable_dropout(model.rnns)
end

function predict()
  reset_state(state_in)
  g_disable_dropout(model.rnns)
    -- loop through input to set states
  local input_len = state_in.data:size(1)
  local predictions = transfer_data(
                          torch.zeros(predict_len + input_len)
                          )
  local _
  g_replace_table(model.s[0], model.start_s)
  print("Starting input forward loop")
  for i = 1,input_len do
    local x = state_in.data[i]
    local y = state_in.data[1] -- y doesn't matter here
    local s = model.s[i - 1]
    local pred
    print("x", x[1])
    perp_tmp, model.s[i], pred = unpack(
                        model.rnns[i]:forward({x, y, s})
                        )
    -- Process prediction
    local pred_slice = pred[{ 1,{} }]:float()
    pred_slice:exp() -- (pred_slice:sum()) -- normalize
    local pred_index = torch.multinomial(pred_slice, 1)
    -- Fill predictions with data
    predictions[i] = state_in.data[{ i,1 }]
    predictions[i+1] = pred_index
    -- _, predictions[i+1] = pred_slice:max(1) -- max
  end

  local x = state_in.data[input_len]

  print("Starting prediction loop")
  for i = input_len+1, predict_len + input_len - 1 do
    local x = torch.ones(params.batch_size):mul(predictions[i])
    -- print("x", x[1])
    local y = state_in.data[1] -- y doesn't matter here
    local s = model.s[i - 1]
    local pred
    perp_tmp, model.s[i], pred = unpack(
                        model.rnns[i]:forward({x, y, s})
                        )
    local pred_slice = pred[{ 1,{} }]:float()
    pred_slice:exp()
    predictions[i+1] = torch.multinomial(pred_slice, 1)
    -- _, predictions[i+1] = pred_slice:max(1) -- max
  end
  g_enable_dropout(model.rnns)
  return predictions
end

function readline()
  local line = io.read("*line")
  if string.len(line) == 0 then
    return false, line
  else
    return true, line
  end
end

function query_sentences()
  -- TODO: make it work for sequences that are longer than seq_length
  
  -- Get and parse query
  print("Query: len word1 word2 etc.")
  local _, line = readline()
  local data = stringx.replace(line, '\n', '<eos>')
  local data = stringx.split(data)
  local data_vec = torch.zeros(#data-1)
  predict_len = tonumber(data[1])
  for i=2,#data do
    print('data[i]', data[i])
    if ptb.vocab_map[data[i]] == nil then
        data[i] = '<unk>'
    end
    data_vec[i-1] = ptb.vocab_map[data[i]]
  end
  data_vec = data_vec:
             resize(data_vec:size(1), 1):
             expand(data_vec:size(1), params.batch_size)
  print("data_vec:size()", data_vec:size())
  -- Create global state
  state_in = {}
  state_in.data = transfer_data(data_vec)

  -- Run generator
  predictions = predict()

  -- Translate results using inverse vocab map
  local predict_output = ''
  for i=1,predictions:size(1) do
    predict_output = predict_output .. ptb.vocab_inv_map[predictions[i]]
  end
  print(predict_output)
end

function assignment_output()
  print("OK GO")
  io.flush()
  ok, line = readline()
  state_in = {}
  while ok do
    -- Prepare input
    local input = ptb.vocab_map[line]
    local x = torch.ones(1, params.batch_size):mul(input)
    state_in.data = transfer_data(x)

    -- Prepare model and get predictions
    g_disable_dropout(model.rnns)
    reset_state(state_in)
    g_replace_table(model.s[0], model.start_s)
    local x = state_in.data[1]
    local y = state_in.data[1]
    -- Since we are not interested in error, we can forward prop without y
    perp, next_s, log_prob = unpack(model.rnns[1]:forward({x,
                                                           y,
                                                           model.s[0]}))

    g_enable_dropout(model.rnns)
    -- Convert predictoins to probabilities and print
    prob_slice = log_prob[{ 1,{} }]:float()
    -- prob_slice:exp()
    -- prob_slice:div(prob_slice:sum())
    out_string = ""
    for i = 1,prob_slice:size(1) do
      if i == 1 then
        out_string = out_string .. prob_slice[i]
      else
        out_string = out_string .. " " .. prob_slice[i]
      end
    end
    print(out_string)
    io.flush()
    
    ok, line = readline()
  end
end

g_init_gpu({1}) -- was g_init_gpu(arg)

if not opt.no_train then
  ----------------------- TRAINING -------------------------
  state_train = {data=transfer_data(ptb.traindataset(params.batch_size))}
  state_valid = {data=transfer_data(ptb.validdataset(params.batch_size))}
  if not opt.char then
    state_test  = {data=transfer_data(ptb.testdataset(params.batch_size))}
  end
  print("Network parameters:")
  print(params)
  local states = {state_train, state_valid, state_test}
  for _, state in pairs(states) do
   reset_state(state)
  end
  setup()
  step = 0
  epoch = 0
  total_cases = 0
  beginning_time = torch.tic()
  start_time = torch.tic()
  print("Starting training.")
  words_per_step = params.seq_length * params.batch_size
  epoch_size = torch.floor(state_train.data:size(1) / params.seq_length)
  --perps
  while epoch < params.max_max_epoch do
   perp = fp(state_train)
   if perps == nil then
     perps = torch.zeros(epoch_size):add(perp)
   end
   perps[step % epoch_size + 1] = perp
   step = step + 1
   bp(state_train)
   total_cases = total_cases + params.seq_length * params.batch_size
   epoch = step / epoch_size
   if step % torch.round(epoch_size / 10) == 10 then
     wps = torch.floor(total_cases / torch.toc(start_time))
     since_beginning = g_d(torch.toc(beginning_time) / 60)
     print('epoch = ' .. g_f3(epoch) ..
           ', train perp. = ' .. g_f3(torch.exp(params.char_mult * perps:mean())) ..
           ', wps = ' .. wps ..
           ', dw:norm() = ' .. g_f3(model.norm_dw) ..
           ', lr = ' ..  g_f3(params.lr) ..
           ', since beginning = ' .. since_beginning .. ' mins.')
   end
   if step % epoch_size == 0 then
     run_valid()
     print("Saving model...")
     torch.save('model.net', model)
     if epoch > params.max_epoch then
         params.lr = params.lr / params.decay
     end
   end
   if step % 33 == 0 then
     cutorch.synchronize()
     collectgarbage()
   end
  end
  run_test()
  print("Training is over.")
-- end -- end of main() 
elseif opt.submission then
     ----------------------- SUBMISSION PREDICTIONS
  -- Load vocabulary map
  ptb.traindataset(params.batch_size)
  -- Load model
  model = torch.load(opt.load_name)
  -- Run assignment
  assignment_output()

else ----------------------- PREDICTIONS FROM USER INPUT

  print("Not training, just playing")
  print("Reading training set to build vocab")
  ptb.traindataset(params.batch_size)

  if opt.load then
    print("Loading model...")
    model = torch.load(opt.load_name)
    query_sentences()
  end
end