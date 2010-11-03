module YTLJit
  module VM
    module ArithmeticOperationUtil
      include AbsArch
      def gen_arithmetic_operation(context, inst, tempreg, resreg)
        context.start_using_reg(tempreg)
        context = gen_eval_self(context)
        asm = context.assembler
        asm.with_retry do
            if context.ret_reg.using(tempreg) then
              asm.mov(TMPR, context.ret_reg)
              context.end_using_reg(context.ret_reg)
              asm.mov(tempreg, TMPR)
            else
              asm.mov(tempreg, context.ret_reg)
              context.end_using_reg(context.ret_reg)
            end
        end
        context.set_reg_content(tempreg, context.ret_node)
        
        # @argunents[1] is block
        # @argunents[2] is self
        # @arguments[3] is other
        aele = @arguments[3]
        context = aele.compile(context)
        context.ret_node.decide_type_once(context.to_signature)
        rtype = context.ret_node.type
        context = rtype.gen_unboxing(context)
          
        asm = context.assembler
        if block_given? then
          yield(context)
        else
          asm.with_retry do
            # default code
            if context.ret_reg.using(tempreg) then
              asm.mov(TMPR, context.ret_reg)
              context.end_using_reg(context.ret_reg)
              asm.send(inst, tempreg, TMPR)
            else
              asm.send(inst, tempreg, context.ret_reg)
              context.end_using_reg(context.ret_reg)
            end
            asm.mov(resreg, tempreg)
          end
        end

        context.end_using_reg(tempreg)

        context.ret_node = self
        context.ret_reg = resreg
        
        decide_type_once(context.to_signature)

        if @type.boxed then
          context = @type.gen_boxing(context)
        end
        
        context
      end
    end

    module CompareOperationUtil
      def gen_compare_operation(context, inst, tempreg, resreg)
        context.start_using_reg(tempreg)
        asm = context.assembler
        asm.with_retry do
          asm.mov(tempreg, context.ret_reg)
        end
        context.set_reg_content(tempreg, context.ret_node)
        
        # @arguments[1] is block
        # @arguments[2] is self
        # @arguments[3] is other arg
        aele = @arguments[3]
        context = aele.compile(context)
        context.ret_node.decide_type_once(context.to_signature)
        rtype = context.ret_node.type
        context = rtype.gen_unboxing(context)
          
        asm = context.assembler
        asm.with_retry do
          if context.ret_reg != resreg then
            asm.mov(resreg, context.ret_reg)
          end
          asm.cmp(resreg, tempreg)
          asm.send(inst, resreg)
          asm.add(resreg, resreg)
        end
        context.end_using_reg(tempreg)
        
        context.ret_node = self
        context.ret_reg = resreg
        
        decide_type_once(context.to_signature)
        if type.boxed then
          context = type.gen_boxing(context)
        end
        
        context
      end
    end
  end
end