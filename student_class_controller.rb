class Tutor::StudentClassController < Tutor::DefaultController

  include Teacher::DataHelper
  helper FolderHelper
  

  def index
    @student_classes = current_user.student.classes_to_show
  end
  
  def join
	# Check if this user is a teacher account, because we only check student account for the duplicate problem
  	is_teacher = ActiveRecord::Base.connection.execute("select * from user_roles where user_id = #{current_user.id} and type = 'Teacher';" )
	if is_teacher.result[0].nil?
		# Get user's first name, last name and birthdate
		current_user_information = ActiveRecord::Base.connection.execute("select first_name, last_name, birthdate from user_details where user_id = #{current_user.id};" )
		if !current_user_information.result.nil?
			current_user_first_name = current_user_information.result[0][0]
			current_user_last_name = current_user_information.result[0][1]
			current_user_birthdate = current_user_information.result[0][2]
		end
		
		# Get the name of the student class by student_class_id
		class_name = ActiveRecord::Base.connection.execute(" select name from student_classes where id = '#{params[:student_class_id]}'")
		if !class_name.result[0].nil?
			@student_class_name = class_name.result[0][0]
		end
		
		# Check if there exist students with same first name, last name and birthdate in this class
		user_id = ActiveRecord::Base.connection.execute("
		select user_id from user_details where user_id in (
		select user_id from user_roles where id in (
		select student_id from enrollments where student_class_id = #{params[:student_class_id]})) 
		and first_name = '#{current_user_first_name}' and last_name = '#{current_user_last_name}' and birthdate = '#{current_user_birthdate}'")
		
		# students with same personal information has already enrolled in this class
		if !user_id.result[0].nil?
			student_user_id = user_id.result[0][0]
			# Get section name
			section_name = ActiveRecord::Base.connection.execute(" select name from student_class_sections where id in (
			select student_class_section_id from enrollments where student_class_id = '#{params[:student_class_id]}' and student_id in (
			select id from user_roles where user_id = #{student_user_id}) )")
			if !section_name.result[0].nil?
				@class_section_name = section_name.result[0][0]
			end
			# Get teacher name
			teacher_name = ActiveRecord::Base.connection.execute("select display_name from user_details where user_id = #{params[:teacher_id]}")
			if !teacher_name.result[0].nil?
				@teacher_displayname = teacher_name.result[0][0]
			end
			# Get login
			login = ActiveRecord::Base.connection.execute("select login from users where id in (
			select user_id from user_details where user_id = #{student_user_id})" )
		end

		if !login.nil? and !login.result[0].nil?
			@enrolled_login = login.result[0][0]
			# tag to record duplicate, true if there exists duplicate account
			@already_enrolled = true
			# Redirect to index to show warning dialog
			if params[:current_student_class_id] != ''
				if params[:current_student_class_id] == 'none'
					redirect_to(:controller => :folder, :action => :index, :already_enrolled => @already_enrolled, :class_section_name => @class_section_name, :enrolled_login => @enrolled_login, :teacher_displayname => @teacher_displayname)
				else
					redirect_to(:controller => :folder, :action => :index, :student_class_id => params[:current_student_class_id], :already_enrolled => @already_enrolled, :class_section_name => @class_section_name, :enrolled_login => @enrolled_login, :teacher_displayname => @teacher_displayname)
				end
			end
			return
		end
	end
	
	isClassJoinable=true
	current_user.student.classes_to_show.each do |joinable|
	  if joinable.id==params[:student_class_id].to_i
		isClassJoinable=false
	  end
	end
	if isClassJoinable
		student_class = StudentClass.find(params[:student_class_id], :include => :class_type)
	class_enroll_require_approval_enabled =  Setting.get_enabled_setting_value(student_class.id, 'class_enroll_require_approval', Scope::CLASS)
	class_type  = class_enroll_require_approval_enabled ? ClassType.find_by_name('approval') : ClassType.find_by_name('unrestricted')
		enrollment_state = EnrollmentState.find_by_name(class_type.name == 'unrestricted' ? 'enrolled' : 'pending')
		enrollment = current_user.student.enrollments.create(:student_class_id => params[:student_class_id], :enrollment_state_id => enrollment_state.id, :student_class_section_id => params[:section_id])
		# Send emails to all teachers if this is an approval-only class and this is
		# the only student with a pending request.
		if class_type.name == 'approval' and Enrollment.count(:all, :conditions => "student_class_id = #{student_class.id} and enrollment_state_id = #{enrollment_state.id}") == 1
		  student_class.teachers.each do |teacher|
			begin
			  UserNotifier::deliver_pending_approvals(teacher.user, student_class) unless teacher.user.email.blank?
			  rescue Exception => e
				ErrorLog.log_exception(e)
			end
		  end
		end
		
		@student_class = current_user.student.find_class_by_enrollment_id(enrollment.id)
		
		# Add existing assignments to records table
		if student_class.enable_arrs?
		  class_assignments = ClassAssignment.find(:all, :conditions=>["student_class_id=? and spiral_assignment_id is null", @student_class.id])
		  class_assignments.each do |assignment|
			unless assignment.individual?
			  if ( assignment.mastery_learning? or
					(defined?(assignment.mastery_type) and
					  !assignment.mastery_type.nil? and
					  assignment.mastery_type == "MasterySection") )
				user = UserRole.find_by_sql("select * from user_roles where user_id=#{current_user.id} and role_id=4 and type='Student'")
				if assignment.due_date.nil?
				  next
				else
				  if assignment.due_date > Time.now
					add_student_reassessment_record(user, assignment.id,  @student_class.id)
				  end
				end
			  end
			end
		  end
		end

		
	else
		@student_class =nil
	end
	
	respond_to do |format|
	  format.html {redirect_to(:controller => :folder, :action => :index, :id => @student_class.id)}
	  format.js
	end
	
  end
  
  def drop
    enrollment = current_user.student.enrollments.find_by_student_class_id(params[:id])
    @student_class = enrollment.student_class
    enrollment.destroy
    @student_classes = current_user.student.classes_to_show
    respond_to do |format|
      format.html {redirect_to(:action => :index)}
      format.js
    end
  end

  def show_student_classes
    @joinable_classes = current_user.student.joinable_classes
    @selected_teacher = params[:teacher_id]
  end

  def show_student_class_sections
    @student_class_sections = StudentClassSection.find_all_by_student_class_id(params[:student_class_id])
    @student_class_sections.sort! {|x, y| x.name.strip.casecmp(y.name.strip)}
  end
  
  def review_assignment
    @student_class = StudentClass.find(params[:student_class_id])
    assignment_log = TutorHelper.get_or_create_assignment_log(current_user.id, params[:student_class_id],'ReviewAssignment')
    return bounce('Could not start that assignment') if assignment_log.nil?
    return bounce('You have already completed that assignment') if assignment_log.complete?
    #return bounce('Could not start that assignment') if (assistment_ids = TutorHelper.flatten(assignment_log[:sequence])).nil?
    @assignment = {
      :class_assignment_id => @student_class.id,
      #:assistment_ids      => assistment_ids,
      :start_time          => assignment_log.start_time.to_f,
      :current_time        => Time.new.to_f,
      :assignment_type     => 'ReviewAssignment'
    }
    render :layout => "tutor"
  end
  
  private
  def bounce(warning = nil)
    set_flash(:warning, warning) unless warning.nil?
    if session[:student_class_id].nil?
      redirect_to(:controller => '/tutor')
    else
      redirect_to(:action => :list, :student_class_id => session[:student_class_id])
    end
    nil
  end
end
