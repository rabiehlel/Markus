class Assignment < ActiveRecord::Base 
  has_many :rubric_criteria, :class_name => "RubricCriterion", :order => :position
  has_many :assignment_files
  has_one  :submission_rule 
  accepts_nested_attributes_for :submission_rule, :allow_destroy => true
  accepts_nested_attributes_for :assignment_files, :allow_destroy => true
  
  has_many :annotation_categories
  
  has_many :groupings
  #TODO:  Do we want these Memberships associated to Assignment?
  has_many :ta_memberships, :through => :groupings
  has_many :student_memberships, :through => :groupings
  
  has_many :submissions, :through => :groupings
  has_many :groups, :through => :groupings
  
  validates_associated :assignment_files
  
  validates_presence_of     :repository_folder
  validates_presence_of     :short_identifier, :group_min
  validates_uniqueness_of   :short_identifier, :case_sensitive => true
  
  validates_numericality_of :group_min, :only_integer => true,  :greater_than => 0
  validates_numericality_of :group_max, :only_integer => true

  validates_associated :submission_rule
  validates_presence_of :submission_rule

  def validate
    if (group_max && group_min) && group_max < group_min
      errors.add(:group_max, "must be greater than the minimum number of groups")
    end
    if Time.zone.parse(due_date.to_s).nil?
      errors.add :due_date, 'is not a valid date'
    else
      
      if due_date_changed? && Time.zone.parse(due_date.to_s) < Time.now
        errors.add :due_date, 'cannot be in the past'
      end
    end
  end
  
  # Are we past the due date for this assignment?
  def past_due_date?
    return Time.now > due_date
  end
  
  def past_collection_date?
    return Time.now > submission_rule.calculate_collection_time
  end
  
  # Returns a Submission instance for this user depending on whether this 
  # assignment is a group or individual assignment
  def submission_by(user) #FIXME: needs schema updates

    # submission owner is either an individual (user) or a group
    owner = self.group_assignment? ? self.group_by(user.id) : user
    return nil unless owner
    
    # create a new submission for the owner 
    # linked to this assignment, if it doesn't exist yet

    # submission = owner.submissions.find_or_initialize_by_assignment_id(id)
    # submission.save if submission.new_record?
    # return submission
    
    
    assignment_groupings = user.active_groupings.delete_if {|grouping| 
      grouping.assignment.id != self.id
    } 
    
    unless assignment_groupings.empty?
      return assignment_groupings.first.submissions.first
    else
      return nil
    end
  end
  
  
  # Return true if this is a group assignment; false otherwise
  def group_assignment?
    instructor_form_groups || group_min != 1 || group_max > 1
  end
  
  # Returns the group by the user for this assignment. If pending=true, 
  # it will return the group that the user has a pending invitation to.
  # Returns nil if user does not have a group for this assignment, or if it is 
  # not a group assignment
  def group_by(uid, pending=false)
    return nil unless group_assignment?
    
    # condition = "memberships.user_id = ?"
    # condition += " and memberships.status != 'rejected'"
    # add non-pending status clause to condition
    # condition += " and memberships.status != 'pending'" unless pending
    # groupings.find(:first, :include => :memberships, :conditions => [condition, uid]) #FIXME: needs schema update
    
    #FIXME: needs to be rewritten using a proper query...
    return User.find(uid).accepted_grouping_for(self.id)    
  end

  # Make a list of students without any groupings
  def no_grouping_students_list
   @students = Student.all(:order => :last_name, :conditions => {:hidden => false})
   @students_list = []
   @students.each do |s|
     if !s.has_accepted_grouping_for?(self.id)
       @students_list.push(s)
      end
   end
   return @students_list
  end
  
  
  # Make a list of the students an inviter can invite for his grouping
  def can_invite_for(gid)
    grouping = Grouping.find(gid)
    students = self.no_grouping_students_list
    students_list = []
    students.each do |s|
      if !grouping.pending?(s)
        students_list.push(s)
      end
    end
    return students_list
  end
  
  # TODO DEPRECATED: use group_assignment? instead
  # Checks if an assignment is an individually-submitted assignment (no groups)
  def individual?
    group_min == 1 && group_max == 1  
  end
  
  def total_mark
    total = 0
    rubric_criteria.each do |criterion|
      total = total + criterion.weight * 4
    end
    return total
  end
  
  # calculates the average of released results for this assignment
  def set_results_average
    groupings = Grouping.find_all_by_assignment_id(self.id)
    results_count = 0
    results_sum = 0
    groupings.each do |grouping|
      submission = grouping.get_submission_used
      if !submission.nil? && submission.has_result?
        result = submission.result
        if result.released_to_students
          results_sum += result.total_mark
          results_count += 1
        end
      end
    end
    if results_count == 0
      return false # no marks released for this assignment
    end
    # Need to avoid divide by zero
    if results_sum == 0
      self.results_average = 0
      return self.save
    end
    avg_quantity = results_sum / results_count
    # compute average in percent
    self.results_average = (avg_quantity * 100 / self.total_mark)
    self.save
  end
  
  def total_criteria_weight
    rubric_criteria.sum('weight')
  end

  def add_group(new_group_name=nil)
    if self.group_name_autogenerated
      group = Group.new
      group.save(false)
      group.group_name = "group_" + group.id.to_s
      group.save
    else
      return nil if new_group_name.nil?
      if Group.find(:first, :conditions => {:group_name => new_group_name})
        group = Group.find(:first, :conditions => {:group_name =>	new_group_name})
        if !self.groupings.find_by_group_id(group.id).nil?
          raise "Group #{new_group_name} already exists"
        end
      else
        group = Group.new
        group.group_name = new_group_name
        group.save
      end
    end
    grouping = Grouping.new
    grouping.group = group
    grouping.assignment = self
    grouping.save
    return grouping
  end


  # Create all the groupings for an assignment where students don't work
  # in groups.
  def create_groupings_when_students_work_alone
     @students = Student.find(:all)
     for @student in @students do
        @student.create_group_for_working_alone_student(self.id)
     end
  end
  
  # Clones the Groupings from the assignment with id assignment_id
  # into self.
  def clone_groupings_from(assignment_id)
    original_assignment = Assignment.find(assignment_id)
    self.group_min = original_assignment.group_min
    self.group_max = original_assignment.group_max
    self.student_form_groups = original_assignment.student_form_groups
    self.group_name_autogenerated = original_assignment.group_name_autogenerated
    self.group_name_displayed = original_assignment.group_name_displayed
    original_assignment.groupings.each do |g|
      #create the groupings
      grouping = Grouping.new
      grouping.assignment_id = self.id
      grouping.group_id = g.group_id
      grouping.save
      #create the memberships
      memberships = g.memberships
      memberships.each do |m|
        membership = Membership.new
        membership.user_id = m.user_id
        membership.grouping_id = grouping.id
        membership.type = m.type
        membership.membership_status = m.membership_status
        membership.save
      end
    end
  end
  
  # Add a group and corresponding grouping as provided in
  # the passed in Array (format: [ groupname, repo_name, member, member, etc ]
  def add_csv_group(group)
    return nil if group.length <= 0
    # If a group with this name already exists, link the grouping to
    # this group. else create the group
    if Group.find(:first, :conditions => {:group_name => group[0]})
      @group = Group.find(:first, :conditions => {:group_name => group[0]})
    else
      @group = Group.new
      @group.group_name = group[0]  
      @group.save
    end
    
    # Group for grouping has to exist at this point
    @grouping = Grouping.new
    @grouping.assignment_id = self.id
    
    # If we are not repository admin, set the repository name as provided
    # in the csv upload file
    if !@group.repository_admin?
      @group.repo_name = group[1].strip # remove whitespace
      @group.save # save new repo_name
    end

    # Form groups
    users_not_found = []
    start_index_group_members = 2 # first field is the group-name, second the repo name, so start at field 3
    for i in start_index_group_members..(group.length-1) do
      student = Student.find_by_user_name(group[i].strip) # remove whitespace
      if student.nil?
        users_not_found << group[i].strip # use this in view to get some meaningful feedback
        return users_not_found
      end
      if (i > start_index_group_members)
        @grouping.add_member(student)
      else
        # Add first member as inviter to group.
        @grouping.group_id = @group.id
        @grouping.save # grouping has to be saved, before we can add members
        @grouping.add_member(student, StudentMembership::STATUSES[:inviter])
      end
    end
    return true
  end
  
  def grouped_students
    result_students = []
    student_memberships.each do |student_membership|
      result_students.push(student_membership.user)
    end
    return result_students
  end
  
  def ungrouped_students
    Student.all - grouped_students
  end
  
  def valid_groupings
    result = []
    groupings.all(:include => [{:student_memberships => :user}]).each do |grouping|
      if grouping.admin_approved || grouping.student_memberships.count >= group_min
        result.push(grouping)
      end
    end
    return result
    #groupings.all(:include => [{:student_memberships => :user}], :joins => :student_memberships, :select => "groupings.*, count(memberships.id) members_count", :group => "memberships.grouping_id", :having => "members_count > 5")
  end
  
  def invalid_groupings
    return groupings - valid_groupings
  end
  
  def assigned_groupings
    return groupings.all(:joins => :ta_memberships, :include => [{:ta_memberships => :user}]).uniq
    
  end

  def unassigned_groupings
    return groupings - assigned_groupings
  end
  
  # Get a list of subversion client commands to be used for scripting
  def get_svn_commands
    svn_commands = [] # the commands to be exported
    groupings = Grouping.find_all_by_assignment_id(self.id)
    groupings.each do |grouping|
      submission = grouping.get_submission_used
      line = ""
      if !submission.nil?
        line += "svn export -r #{submission.revision_number} #{grouping.group.repository_external_access_url} #{grouping.group.group_name}"
      end
      if line != ""
        svn_commands.push(line)
      end
    end
    return svn_commands
  end
  
  def replace_submission_rule(new_submission_rule)
    if self.submission_rule.nil?
      self.submission_rule = new_submission_rule
      self.save
    else
      self.submission_rule.destroy
      self.submission_rule = new_submission_rule
      self.save
    end
  end
  
end
